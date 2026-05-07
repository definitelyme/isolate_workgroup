/// addIsolate() dynamic-scaling tests.
/// Spec §7.7.
@TestOn('vm')
library;

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';
import '_support/members.dart';

void throwingSetup() {
  throw StateError('addIsolate-setup-fail');
}

void main() {
  group('addIsolate()', () {
    test('returns new index = old isolatesCount; both counters increment',
        () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      expect(wg.isolatesCount, 2);
      expect(wg.liveIsolateCount, 2);

      final newIndex = await wg.addIsolate();
      expect(newIndex, 2, reason: 'new index = old isolatesCount');
      expect(wg.isolatesCount, 3);
      expect(wg.liveIsolateCount, 3);

      final newIndex2 = await wg.addIsolate();
      expect(newIndex2, 3);
      expect(wg.isolatesCount, 4);
      expect(wg.liveIsolateCount, 4);

      wg.shutdown();
    });

    test('throws when state == idle (pre-launch)', () async {
      final wg = IsolateWorkgroup(2);
      await expectLater(
        wg.addIsolate(),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('throws when state == disposed (post-shutdown)', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      wg.shutdown();
      await expectLater(
        wg.addIsolate(),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('debugLabel produces label suffixed by the new index', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();

      final newIndex = await wg.addIsolate(debugLabel: 'custom');
      // The error/stream port maps are keyed by the same debug name.
      final keys = wg.errorReceivePortsStreamsMap.keys.toSet();
      expect(keys, contains('custom_$newIndex'));
      expect(wg.receivePortsStreamsMap.keys, contains('custom_$newIndex'));

      wg.shutdown();
    });

    test(
      'onSetup failure rolls back: liveIsolateCount unchanged, '
      'no leftover state for the new index',
      () async {
        final wg = IsolateWorkgroup(
          2,
          // No initial setup, so the original 2 launch cleanly.
        );
        await wg.launch();
        // After launch, swap to a config with a throwing onSetup. We can't
        // mutate WorkgroupConfig, so we re-create the workgroup with a
        // throwing onSetup and launch — initial isolates also fail, but
        // the addIsolate behavior is what we're after.
        wg.shutdown();

        final wgFail = IsolateWorkgroup(
          1,
          config: const WorkgroupConfig(onSetup: throwingSetup),
        );
        wgFail.setErrorHandler(IsolateErrorType.all, (_) {});
        // Pre-attach so the ready rejection is caught.
        // ignore: unawaited_futures
        wgFail.ready.catchError((Object _) {});
        await wgFail.launch();

        final beforeLive = wgFail.liveIsolateCount;
        final beforeCount = wgFail.isolatesCount;

        await expectLater(
          wgFail.addIsolate(debugLabel: 'failing'),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            contains('Failed to add isolate'),
          )),
        );

        // isolatesCount is NOT incremented on failure.
        expect(wgFail.isolatesCount, beforeCount);
        // No port-map entries leaked for the failed index.
        expect(
          wgFail.receivePortsStreamsMap.keys
              .where((k) => k.startsWith('failing_'))
              .toList(),
          isEmpty,
        );
        // _isolates entry for the failed index removed (live count unchanged).
        expect(wgFail.liveIsolateCount, beforeLive);

        wgFail.shutdown();
      },
    );

    test(
      'kill + addIsolate produces a monotonic, non-reused index',
      () async {
        final wg = IsolateWorkgroup(4);
        await wg.launch();

        wg.kill(1);
        // After kill, isolatesCount is still 4. addIsolate's new index = 4.
        final newIndex = await wg.addIsolate();
        expect(newIndex, 4, reason: 'new index does not reuse killed slot');
        expect(wg.isolatesCount, 5);
        // Index 1 stays dead.
        expect(wg.liveIsolateCount, 4);

        wg.shutdown();
      },
    );

    test('after addIsolate, dispatch can target the new index', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();

      final newIndex = await wg.addIsolate();
      final result = await wg.dispatch(EchoJob<int>(123), newIndex);
      expect(result, 123);

      wg.shutdown();
    });

    test('after addIsolate, addInstance load-balances onto it', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();

      // Pre-populate isolates 0 and 1 with one instance each.
      await wg.addInstance(EchoMember(), isolateIndex: 0);
      await wg.addInstance(EchoMember(), isolateIndex: 1);

      final newIndex = await wg.addIsolate();
      // The new isolate has 0 instances; load-balanced addInstance should
      // pick it.
      final p = await wg.addInstance(EchoMember());
      expect(p.workerIndex, newIndex);

      wg.shutdown();
    });

    test(
      'multiple addIsolate calls are independent and increment count',
      () async {
        final wg = IsolateWorkgroup(1);
        await wg.launch();

        for (var i = 0; i < 3; i++) {
          final idx = await wg.addIsolate(debugLabel: 'extra');
          expect(idx, 1 + i);
        }
        expect(wg.isolatesCount, 4);
        expect(wg.liveIsolateCount, 4);

        wg.shutdown();
      },
    );
  });
}
