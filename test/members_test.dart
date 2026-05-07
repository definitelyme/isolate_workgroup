/// Member lifecycle tests for [WorkgroupMember] / [MemberProxy].
/// Spec §7.4 — addInstance / destroyInstance / dispose / invoke / notifyHost.
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/commands.dart';
import '_support/members.dart';
import '_support/probes.dart';

// Top-level counter incremented inside each worker isolate's copy when
// [_DisposeTrackingMember.dispose] runs. Read back via
// [_ReadDisposeCountJob] dispatched on the same isolate index.
int _isolateDisposeCount = 0;

class _DisposeTrackingMember extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async => null;

  @override
  Future<void> dispose() async {
    _isolateDisposeCount++;
  }
}

class _ReadDisposeCountJob extends WorkgroupJob<int> {
  @override
  Future<int> execute() async => _isolateDisposeCount;
}


void main() {
  group('addInstance', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(4);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test(
      'load-balances onto isolates with the fewest instances when '
      'isolateIndex is omitted',
      () async {
        // 4 instances on 4 isolates → 1 each.
        final proxies = <MemberProxy>[];
        for (var i = 0; i < 4; i++) {
          proxies.add(await wg.addInstance(EchoMember()));
        }
        final indices = proxies.map((p) => p.workerIndex).toSet();
        expect(indices.length, 4,
            reason: 'each instance should land on a distinct isolate');
      },
    );

    test('explicit isolateIndex routes the instance', () async {
      final proxy = await wg.addInstance(EchoMember(), isolateIndex: 2);
      expect(proxy.workerIndex, 2);
    });

    test(
      'invalid (out-of-range) isolateIndex throws WorkgroupException',
      () async {
        await expectLater(
          wg.addInstance(EchoMember(), isolateIndex: 99),
          throwsA(isA<WorkgroupException>()),
        );
      },
    );

    test(
      'killed-isolate index throws WorkgroupException',
      () async {
        wg.kill(1);
        await expectLater(
          wg.addInstance(EchoMember(), isolateIndex: 1),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            contains('killed'),
          )),
        );
      },
    );

    test(
      'caught: setup throws → future rejects with original error type',
      () async {
        await expectLater(
          wg.addInstance(FailingSetupMember('setup-fail')),
          throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'toString()',
            contains('setup-fail'),
          )),
        );
      },
    );

    test(
      'unhandled: setup throws → reaches runZonedGuarded zone',
      () async {
        final (err, _) = await captureUnhandled(() {
          // ignore: unawaited_futures
          wg.addInstance(FailingSetupMember('zone-setup-fail'));
        });
        expect(err.toString(), contains('zone-setup-fail'));
      },
    );

    test(
      'caught: non-sendable member → WorkgroupException with validation list',
      () async {
        await expectLater(
          wg.addInstance(StreamHoldingNonSendableMember()),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            contains('NEVER sendable'),
          )),
        );
      },
    );

    test('slow setup returns proxy only after setup completes', () async {
      final sw = Stopwatch()..start();
      final proxy = await wg.addInstance(SlowSetupMember(150));
      sw.stop();
      expect(proxy, isA<MemberProxy>());
      // Slow setup is 150ms; the round-trip must take at least that long.
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(140));
    });

    test('callback parameter wires up host-side handler', () async {
      // Track host invocations.
      final received = <Object?>[];
      Object? hostHandler(WorkerCommand cmd) {
        if (cmd is NotifyHostCommand) {
          received.add(cmd.payload);
          return 'ack-${cmd.payload}';
        }
        return null;
      }

      final proxy = await wg.addInstance<Object?>(
        NotifyingMember(),
        callback: hostHandler,
      );
      final ack = await proxy.invoke<Object?>(NotifyHostCommand('hello'));
      expect(ack, 'ack-hello');
      expect(received, ['hello']);
    });
  });

  group('destroyInstance', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(2);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test('silent no-op for already-destroyed', () async {
      final proxy = await wg.addInstance(EchoMember(), isolateIndex: 0);
      wg.destroyInstance(proxy);
      // Second destroy is a silent no-op — must not throw.
      wg.destroyInstance(proxy);
      expect(wg.memberCount, 0);
    });

    test('mismatched explicit isolate throws WorkgroupException', () async {
      final proxy = await wg.addInstance(EchoMember(), isolateIndex: 0);
      expect(
        () => wg.destroyInstance(proxy, isolate: 1),
        throwsA(isA<WorkgroupException>().having(
          (e) => e.message,
          'message',
          contains('not on isolate 1'),
        )),
      );
      wg.destroyInstance(proxy);
    });

    test(
      'triggers WorkgroupMember.dispose() (verified via per-isolate counter)',
      () async {
        // Pin to isolate 0 so we can read the counter back from the same one.
        final proxy = await wg.addInstance(
          _DisposeTrackingMember(),
          isolateIndex: 0,
        );
        // Baseline counter = 0.
        expect(await wg.dispatch(_ReadDisposeCountJob(), 0), 0);

        wg.destroyInstance(proxy);
        // Give the worker a moment to process the DestroyRequest.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(await wg.dispatch(_ReadDisposeCountJob(), 0), 1);
      },
    );

    test(
      'after shutdown throws WorkgroupException '
      '(observed-and-locked: shutdown doesn\'t clear _pooledInstances, '
      'so destroyInstance walks past the early-out and hits a null sendPort)',
      () async {
        final proxy = await wg.addInstance(EchoMember(), isolateIndex: 0);
        wg.shutdown();
        expect(
          () => wg.destroyInstance(proxy),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            contains('SendPort is null'),
          )),
        );
      },
    );
  });

  group('invoke', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(2);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test('round-trip success', () async {
      final proxy = await wg.addInstance(EchoMember());
      final r = await proxy.invoke<int>(EchoCommand<int>(7));
      expect(r, 7);
    });

    test('caught: error inside handle() rejects the invoke future',
        () async {
      final proxy = await wg.addInstance(EchoMember());
      await expectLater(
        proxy.invoke<dynamic>(ThrowCommand('handle-boom')),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'toString()',
          contains('handle-boom'),
        )),
      );
    });

    test('unhandled: handle() error reaches runZonedGuarded zone', () async {
      final proxy = await wg.addInstance(EchoMember());
      final (err, _) = await captureUnhandled(() {
        // ignore: unawaited_futures
        proxy.invoke<dynamic>(ThrowCommand('zone-handle-boom'));
      });
      expect(err.toString(), contains('zone-handle-boom'));
    });

    test('large payload (10 KB list) round-trip', () async {
      final big = List<int>.generate(10000, (i) => i);
      final proxy = await wg.addInstance(EchoMember());
      final r = await proxy.invoke<List<int>>(EchoCommand<List<int>>(big));
      expect(r.length, 10000);
      expect(r.first, 0);
      expect(r.last, 9999);
    });

    test(
      'cross-isolate via `isolate:` parameter — sends to specified isolate',
      () async {
        // Add the same instance type to both isolates.
        final p0 = await wg.addInstance(CounterMember(), isolateIndex: 0);
        await wg.addInstance(CounterMember(), isolateIndex: 1);

        // Increment p0 normally.
        await p0.invoke<int>(IncrementCounter());
        expect(await p0.invoke<int>(GetCounter()), 1);

        // Cross-isolate call: invoke with isolate: 1 — but p0's memberId
        // doesn't exist on isolate 1, so this fails with a member-not-found
        // error. We assert that the routing IS attempted (current behavior).
        await expectLater(
          p0.invoke<int>(GetCounter(), isolate: 1),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'after shutdown throws WorkgroupInactiveException synchronously',
      () async {
        final proxy = await wg.addInstance(EchoMember());
        wg.shutdown();
        expect(
          () => proxy.invoke<int>(EchoCommand<int>(1)),
          throwsA(isA<WorkgroupInactiveException>()),
        );
      },
    );

    test(
      'many concurrent commands to same instance preserve correlation',
      () async {
        final proxy = await wg.addInstance(EchoMember());
        final futures = <Future<int>>[];
        for (var i = 0; i < 50; i++) {
          futures.add(proxy.invoke<int>(EchoCommand<int>(i)));
        }
        final results = await Future.wait(futures);
        for (var i = 0; i < 50; i++) {
          expect(results[i], i, reason: 'request $i should map back to $i');
        }
      },
    );
  });

  group('notifyHost', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(2);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test('round-trip success returns host result', () async {
      final proxy = await wg.addInstance<Object?>(
        NotifyingMember(),
        callback: (cmd) {
          if (cmd is NotifyHostCommand) {
            return 'host-saw-${cmd.payload}';
          }
          return null;
        },
      );
      final r = await proxy.invoke<Object?>(NotifyHostCommand('ping'));
      expect(r, 'host-saw-ping');
    });

    test(
      'with no remoteCallback: notifyHost never resolves (observed-and-locked)',
      () async {
        // Current behavior: when no callback is set, the host-side
        // _processRequest prints a warning and returns without sending a
        // Response. notifyHost's internal future never completes. Locking
        // this in here so future regressions are visible.
        final proxy = await wg.addInstance(NotifyingMember());

        // Race the invoke against a 250ms timeout — confirm it does NOT
        // resolve.
        final fut = proxy.invoke<Object?>(NotifyHostCommand('x'));
        final racer = await Future.any<Object?>([
          fut.then<Object?>((v) => 'resolved'),
          Future.delayed(const Duration(milliseconds: 250),
              () => 'timed-out'),
        ]);
        expect(racer, 'timed-out',
            reason:
                'notifyHost without remoteCallback must not resolve (current behavior)');
      },
    );
  });

  group('multiple instances / indexOfInstance', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(2);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test(
      'multiple counters on the same isolate keep per-instance state',
      () async {
        final c0 = await wg.addInstance(CounterMember(), isolateIndex: 0);
        final c1 = await wg.addInstance(CounterMember(), isolateIndex: 0);

        await c0.invoke<int>(IncrementCounter());
        await c0.invoke<int>(IncrementCounter());
        await c1.invoke<int>(IncrementCounter());

        expect(await c0.invoke<int>(GetCounter()), 2);
        expect(await c1.invoke<int>(GetCounter()), 1);
      },
    );

    test('indexOfInstance returns correct isolate', () async {
      final p0 = await wg.addInstance(EchoMember(), isolateIndex: 0);
      final p1 = await wg.addInstance(EchoMember(), isolateIndex: 1);
      expect(wg.indexOfInstance(p0), 0);
      expect(wg.indexOfInstance(p1), 1);
    });

    test('indexOfInstance returns -1 for unknown', () async {
      // Build a proxy that is not in the pool.
      final p0 = await wg.addInstance(EchoMember(), isolateIndex: 0);
      wg.destroyInstance(p0);
      expect(wg.indexOfInstance(p0), -1);
    });
  });

  group('state invariants', () {
    test(
      'memberCount tracks add/destroy and lands at 0 after a full cycle',
      () async {
        final wg = IsolateWorkgroup(2);
        await wg.launch();

        expect(wg.memberCount, 0);
        final p1 = await wg.addInstance(EchoMember());
        expect(wg.memberCount, 1);
        final p2 = await wg.addInstance(EchoMember());
        expect(wg.memberCount, 2);
        wg.destroyInstance(p1);
        expect(wg.memberCount, 1);
        wg.destroyInstance(p2);
        expect(wg.memberCount, 0);

        wg.shutdown();
        expectAllStateMapsEmpty(wg);
      },
    );
  });
}
