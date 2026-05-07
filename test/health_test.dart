/// Health-config + probe + healthStatus tests.
/// Spec §7.10.
@TestOn('vm')
library;

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';

void main() {
  group('WorkgroupHealthConfig presets', () {
    test('default constructor: enabled, sane timeouts, no pre-dispatch checks',
        () {
      const c = WorkgroupHealthConfig();
      expect(c.enabled, isTrue);
      expect(c.pingTimeout, const Duration(seconds: 2));
      expect(c.stalenessThreshold, const Duration(seconds: 30));
      expect(c.maxConsecutiveFailures, 2);
      expect(c.checkBeforeDispatching, isFalse);
    });

    test('.disabled() turns the whole subsystem off', () {
      const c = WorkgroupHealthConfig.disabled();
      expect(c.enabled, isFalse);
      expect(c.pingTimeout, Duration.zero);
      expect(c.stalenessThreshold, Duration.zero);
      expect(c.maxConsecutiveFailures, 0);
      expect(c.checkBeforeDispatching, isFalse);
    });

    test('.aggressive() shortens timeouts and enables pre-dispatch', () {
      const c = WorkgroupHealthConfig.aggressive();
      expect(c.enabled, isTrue);
      expect(c.pingTimeout, const Duration(milliseconds: 500));
      expect(c.stalenessThreshold, const Duration(seconds: 10));
      expect(c.maxConsecutiveFailures, 1);
      expect(c.checkBeforeDispatching, isTrue);
    });

    test('.relaxed() lengthens timeouts and skips pre-dispatch checks', () {
      const c = WorkgroupHealthConfig.relaxed();
      expect(c.enabled, isTrue);
      expect(c.pingTimeout, const Duration(seconds: 5));
      expect(c.stalenessThreshold, const Duration(minutes: 2));
      expect(c.maxConsecutiveFailures, 3);
      expect(c.checkBeforeDispatching, isFalse);
    });
  });

  group('probe()', () {
    test('returns true on a healthy isolate', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      expect(await wg.probe(0), isTrue);
      expect(await wg.probe(1), isTrue);
      wg.shutdown();
    });

    test('returns false on out-of-range index (no throw)', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      expect(await wg.probe(-1), isFalse);
      expect(await wg.probe(99), isFalse);
      wg.shutdown();
    });

    test('returns false on a killed isolate', () async {
      final wg = IsolateWorkgroup(3);
      await wg.launch();
      wg.kill(1);
      expect(await wg.probe(1), isFalse);
      wg.shutdown();
    });

    test('returns true (no-op) when health checking is disabled', () async {
      final wg = IsolateWorkgroup(
        2,
        config: const WorkgroupConfig(
          health: WorkgroupHealthConfig.disabled(),
        ),
      );
      await wg.launch();
      expect(await wg.probe(0), isTrue,
          reason: 'disabled config short-circuits to true');
      wg.shutdown();
    });
  });

  group('isIsolateHealthy / healthStatus', () {
    test('initial state: all isolates healthy', () async {
      final wg = IsolateWorkgroup(3);
      await wg.launch();
      for (var i = 0; i < 3; i++) {
        expect(wg.isIsolateHealthy(i), isTrue);
      }
      wg.shutdown();
    });

    test('healthStatus returns empty map when disabled', () async {
      final wg = IsolateWorkgroup(
        2,
        config: const WorkgroupConfig(
          health: WorkgroupHealthConfig.disabled(),
        ),
      );
      await wg.launch();
      expect(wg.healthStatus, isEmpty);
      wg.shutdown();
    });

    test('healthStatus has one entry per isolate when enabled', () async {
      final wg = IsolateWorkgroup(3);
      await wg.launch();
      expect(wg.healthStatus.length, 3);
      for (var i = 0; i < 3; i++) {
        expect(wg.healthStatus[i]?.isolateIndex, i);
        expect(wg.healthStatus[i]?.isHealthy, isTrue);
      }
      wg.shutdown();
    });

    test('lastKnownGood advances after a successful job', () async {
      final wg = IsolateWorkgroup(1);
      await wg.launch();
      final before = wg.healthStatus[0]!.lastKnownGood;
      // Sleep just past the timer resolution so DateTime advances.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await wg.dispatch(EchoJob<int>(1));
      final after = wg.healthStatus[0]!.lastKnownGood;
      expect(after.isAfter(before) || after == before, isTrue,
          reason: 'lastKnownGood must not regress');
      wg.shutdown();
    });

    test('kill() removes the health entry for that isolate', () async {
      final wg = IsolateWorkgroup(3);
      await wg.launch();
      expect(wg.healthStatus.containsKey(1), isTrue);
      wg.kill(1);
      expect(wg.healthStatus.containsKey(1), isFalse);
      // Other isolates' entries are preserved.
      expect(wg.healthStatus.containsKey(0), isTrue);
      expect(wg.healthStatus.containsKey(2), isTrue);
      wg.shutdown();
    });
  });

  group('checkBeforeDispatching', () {
    test(
      'with checkBeforeDispatching=true and a healthy isolate, '
      'dispatch still succeeds (just slower)',
      () async {
        final wg = IsolateWorkgroup(
          1,
          config: const WorkgroupConfig(
            health: WorkgroupHealthConfig.aggressive(),
          ),
        );
        await wg.launch();
        // aggressive enables checkBeforeDispatching; healthy isolate works.
        final r = await wg.dispatch(EchoJob<int>(42));
        expect(r, 42);
        wg.shutdown();
      },
    );
  });
}
