/// Concurrency stress tests. Tagged `slow`; excluded from default `dart test`.
/// Spec §7.13.
@TestOn('vm')
@Tags(['slow'])
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';
import '_support/members.dart';
import '_support/probes.dart';

void main() {
  test('1000 dispatches / 4 workers all complete with correct results',
      () async {
    final wg = IsolateWorkgroup(4);
    await wg.launch();

    final futures = <Future<int>>[];
    for (var i = 0; i < 1000; i++) {
      futures.add(wg.dispatch(AddJob(i, 1)));
    }
    final results = await Future.wait(futures);
    for (var i = 0; i < 1000; i++) {
      expect(results[i], i + 1);
    }
    expect(wg.pendingCount, 0);

    wg.shutdown();
  });

  test('100 instances on 4 workers — distribution count delta ≤ 1', () async {
    final wg = IsolateWorkgroup(4);
    await wg.launch();

    for (var i = 0; i < 100; i++) {
      await wg.addInstance(EchoMember());
    }
    final perIsolate = <int, int>{};
    for (final entry in wg.members.values) {
      perIsolate[entry.isolateIndex] =
          (perIsolate[entry.isolateIndex] ?? 0) + 1;
    }
    expect(perIsolate.length, 4);
    final counts = perIsolate.values.toList()..sort();
    expect(counts.last - counts.first, lessThanOrEqualTo(1),
        reason:
            'load-balanced add must keep per-isolate count delta ≤ 1 (got: $counts)');

    wg.shutdown();
  });

  test(
    'kill while a slow job is in flight on that isolate — '
    'that job rejects; others on other isolates complete uninterrupted',
    () async {
      final wg = IsolateWorkgroup(3);
      await wg.launch();

      // Schedule a slow job on isolate 1.
      final slow1 = wg.dispatch(SleepJob(2000, 'slow-1'), 1);
      // Schedule fast jobs on isolates 0 and 2.
      final fast0 = wg.dispatch(SleepJob(50, 'ok-0'), 0);
      final fast2 = wg.dispatch(SleepJob(50, 'ok-2'), 2);

      // Give isolate 1 a moment to start its slow job.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      wg.kill(1);

      // slow1 must reject.
      await expectLater(slow1, throwsA(isA<WorkgroupException>()));
      // Others must complete normally.
      expect(await fast0, 'ok-0');
      expect(await fast2, 'ok-2');

      wg.shutdown();
    },
  );

  test(
    '20 cycles of new workgroup → launch → 100 dispatches → shutdown '
    'leave no leftover observable state',
    () async {
      for (var cycle = 0; cycle < 20; cycle++) {
        final wg = IsolateWorkgroup(2);
        await wg.launch();
        final futures = <Future<int>>[];
        for (var i = 0; i < 100; i++) {
          futures.add(wg.dispatch(AddJob(cycle, i)));
        }
        await Future.wait(futures);
        wg.shutdown();
        expect(wg.state, WorkgroupState.disposed);
        expectAllStateMapsEmpty(wg);
      }
    },
  );

  test(
    '50 cycles of (kill random isolate; addIsolate) under sustained dispatch '
    '— all eventually-active jobs complete',
    () async {
      // Start with 4 isolates; we'll churn the membership while dispatching.
      final wg = IsolateWorkgroup(4);
      await wg.launch();

      final rng = math.Random(42);
      var done = false;

      // Background dispatcher.
      final results = <int>[];
      final dispatchFutures = <Future>[];
      Future<void> spammer() async {
        var i = 0;
        while (!done) {
          // Use -1 so the workgroup picks any alive isolate.
          dispatchFutures.add(
            wg.dispatch(AddJob(i, 1)).then(results.add).catchError((Object _) {
              // Some dispatches may fail because the targeted isolate dies
              // mid-flight. That's expected — they go to error.
            }),
          );
          i++;
          // Yield to let the workgroup process.
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }

      final spamFut = spammer();

      for (var cycle = 0; cycle < 50; cycle++) {
        // Pick an alive isolate to kill.
        final alive = <int>[];
        for (var i = 0; i < wg.isolatesCount; i++) {
          if (wg.healthStatus.containsKey(i)) {
            alive.add(i);
          }
        }
        if (alive.length > 1) {
          final victim = alive[rng.nextInt(alive.length)];
          wg.kill(victim);
        }
        await wg.addIsolate();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      done = true;
      await spamFut;
      // Drain in-flight dispatches.
      await Future.wait(dispatchFutures);

      // At least some results must have come through.
      expect(results, isNotEmpty);

      wg.shutdown();
    },
  );

  test(
    'race: simultaneous dispatch + addInstance + kill survives gracefully',
    () async {
      // We can't deterministically assert outcomes for racing operations
      // — but the workgroup must not deadlock or corrupt state.
      final wg = IsolateWorkgroup(4);
      await wg.launch();

      final ops = <Future>[];
      for (var i = 0; i < 20; i++) {
        ops.add(wg.dispatch(EchoJob<int>(i)).catchError((Object _) => -1));
      }
      for (var i = 0; i < 5; i++) {
        ops.add(
          wg
              .addInstance(EchoMember())
              .catchError((Object _) => MemberProxy<dynamic>(
                    memberId: -1,
                    workerIndex: -1,
                    workgroup: wg,
                    remoteCallback: null,
                  )),
        );
      }
      // Kill one isolate mid-race.
      Timer(const Duration(milliseconds: 5), () {
        if (wg.liveIsolateCount > 1) {
          try {
            wg.kill(0);
          } catch (_) {/* tolerate races */}
        }
      });
      await Future.wait(ops);

      // Workgroup is still in a usable state.
      expect(wg.state, WorkgroupState.active);
      wg.shutdown();
    },
  );
}
