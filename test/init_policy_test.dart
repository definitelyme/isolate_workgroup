/// InitializationPolicy.concurrent vs sequential.
/// Spec §7.12.
@TestOn('vm')
library;

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';

Future<void> sleep100() async {
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

void throwingSetup() {
  throw StateError('init-policy-fail');
}

void main() {
  group('InitializationPolicy', () {
    test(
      'concurrent: total launch time ≈ slowest single setup '
      '(parallel startup)',
      () async {
        final wg = IsolateWorkgroup(
          4,
          config: const WorkgroupConfig(
            onSetup: sleep100,
            startupPolicy: InitializationPolicy.concurrent,
          ),
        );
        final sw = Stopwatch()..start();
        await wg.launch();
        sw.stop();

        // Each setup sleeps 100ms; concurrent should be roughly 100-300ms,
        // not 400ms+. Be generous to avoid CI flake.
        expect(sw.elapsedMilliseconds, lessThan(350),
            reason:
                'concurrent must not serialize setups (took ${sw.elapsedMilliseconds}ms)');
        wg.shutdown();
      },
    );

    test(
      'sequential: total launch time ≈ sum of setup times',
      () async {
        final wg = IsolateWorkgroup(
          4,
          config: const WorkgroupConfig(
            onSetup: sleep100,
            startupPolicy: InitializationPolicy.sequential,
          ),
        );
        final sw = Stopwatch()..start();
        await wg.launch();
        sw.stop();

        // Each setup sleeps 100ms; sequential should be at least
        // ~400ms total (4 × 100ms) and noticeably more than concurrent.
        expect(sw.elapsedMilliseconds, greaterThan(350),
            reason:
                'sequential must serialize setups (took ${sw.elapsedMilliseconds}ms)');
        wg.shutdown();
      },
    );

    test(
      'sequential with throwing setup — observed-and-locked behavior',
      () async {
        final wg = IsolateWorkgroup(
          2,
          config: const WorkgroupConfig(
            onSetup: throwingSetup,
            startupPolicy: InitializationPolicy.sequential,
          ),
        );
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        // Pre-attach to ready so the rejection isn't reported uncaught.
        final readyExpect = expectLater(
          wg.ready,
          throwsA(isA<WorkgroupSetupException>()),
        );
        await wg.launch();
        await readyExpect;
        // Despite setup failures, state advances to active (current behavior).
        expect(wg.state, WorkgroupState.active);
        wg.shutdown();
      },
    );

    test(
      'concurrent vs sequential happy path produce identical functional '
      'outcomes',
      () async {
        final concurrent = IsolateWorkgroup(
          2,
          config: const WorkgroupConfig(
            startupPolicy: InitializationPolicy.concurrent,
          ),
        );
        await concurrent.launch();
        final r1 = await concurrent.dispatch(AddJob(2, 3));
        final r2 = await concurrent.dispatch(EchoJob<int>(7));
        concurrent.shutdown();

        final sequential = IsolateWorkgroup(
          2,
          config: const WorkgroupConfig(
            startupPolicy: InitializationPolicy.sequential,
          ),
        );
        await sequential.launch();
        final s1 = await sequential.dispatch(AddJob(2, 3));
        final s2 = await sequential.dispatch(EchoJob<int>(7));
        sequential.shutdown();

        expect(s1, r1);
        expect(s2, r2);
      },
    );

    test('default policy is concurrent', () {
      const cfg = WorkgroupConfig();
      expect(cfg.startupPolicy, InitializationPolicy.concurrent);
    });
  });
}
