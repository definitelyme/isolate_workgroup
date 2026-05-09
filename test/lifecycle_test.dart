/// Lifecycle and state-machine tests for [IsolateWorkgroup].
///
/// Spec §7.2 — launch / shutdown / state / ready / 0-iso /
/// onSetup / labelBuilder.
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';
import '_support/probes.dart';

// ---------------------------------------------------------------------------
// Top-level setup helpers — must be top-level / static so they are sendable.
// ---------------------------------------------------------------------------

void successfulSetup() {
  // No-op; success path.
}

Future<void> asyncSuccessfulSetup() async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
}

void throwingSetup() {
  throw StateError('boom from setup');
}

Future<void> asyncThrowingSetup() async {
  await Future<void>.delayed(const Duration(milliseconds: 5));
  throw StateError('boom from async setup');
}

String customLabel(int i) => 'custom_worker_$i';

// ---------------------------------------------------------------------------

void main() {
  group('launch()', () {
    test('transitions idle → active and exposes isolatesCount', () async {
      final wg = IsolateWorkgroup(3);
      expect(wg.state, WorkgroupState.idle);
      expect(wg.isolatesCount, 3);

      await wg.launch();
      expect(wg.state, WorkgroupState.active);
      expect(wg.isolatesCount, 3);
      expect(wg.liveIsolateCount, 3);

      wg.shutdown();
    });

    test('second launch() throws WorkgroupException', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      await expectLater(wg.launch(), throwsA(isA<WorkgroupException>()));
      wg.shutdown();
    });

    test('launch() after shutdown throws WorkgroupException', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      wg.shutdown();
      await expectLater(wg.launch(), throwsA(isA<WorkgroupException>()));
    });
  });

  group('ready', () {
    test('resolves once launch completes (success path)', () async {
      final wg = IsolateWorkgroup(2);
      final readyFuture = wg.ready;
      await wg.launch();
      // ready is a Future that should already be (or soon be) complete.
      await readyFuture;
      expect(wg.state, WorkgroupState.active);
      wg.shutdown();
    });

    test(
      'concurrent setup that throws → ready rejects with WorkgroupSetupException '
      '(launch() itself resolves; observed-and-locked behavior)',
      () async {
        final wg = IsolateWorkgroup(
          2,
          config: const WorkgroupConfig(onSetup: throwingSetup),
        );
        // Suppress error-port noise.
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        // Pre-attach a listener so the error is not "uncaught" before
        // launch() returns.
        final readyExpect = expectLater(
          wg.ready,
          throwsA(isA<WorkgroupSetupException>()),
        );
        // Current behavior: launch() resolves even when setup throws —
        // the failure surface is `wg.ready`, not the launch() future.
        await wg.launch();
        await readyExpect;
        wg.shutdown();
      },
    );

    test(
      'sequential setup that throws → ready rejects with WorkgroupSetupException',
      () async {
        final wg = IsolateWorkgroup(
          2,
          config: const WorkgroupConfig(
            onSetup: throwingSetup,
            startupPolicy: InitializationPolicy.sequential,
          ),
        );
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        final readyExpect = expectLater(
          wg.ready,
          throwsA(isA<WorkgroupSetupException>()),
        );
        await wg.launch();
        await readyExpect;
        wg.shutdown();
      },
    );

    test('async successful setup launches normally', () async {
      final wg = IsolateWorkgroup(
        2,
        config: const WorkgroupConfig(onSetup: asyncSuccessfulSetup),
      );
      await wg.launch();
      expect(wg.state, WorkgroupState.active);
      wg.shutdown();
    });

    test(
      'async setup that throws → ready rejects with WorkgroupSetupException',
      () async {
        final wg = IsolateWorkgroup(
          2,
          config: const WorkgroupConfig(onSetup: asyncThrowingSetup),
        );
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        final readyExpect = expectLater(
          wg.ready,
          throwsA(isA<WorkgroupSetupException>()),
        );
        await wg.launch();
        await readyExpect;
        wg.shutdown();
      },
    );
  });

  group('state getter', () {
    test('returns idle / active / disposed at appropriate times', () async {
      final wg = IsolateWorkgroup(2);
      expect(wg.state, WorkgroupState.idle);
      await wg.launch();
      expect(wg.state, WorkgroupState.active);
      wg.shutdown();
      expect(wg.state, WorkgroupState.disposed);
    });
  });

  group('zero-isolate workgroup', () {
    test('launches and reaches active state', () async {
      final wg = IsolateWorkgroup(0);
      await wg.launch();
      expect(wg.state, WorkgroupState.active);
      expect(wg.isolatesCount, 0);
      expect(wg.liveIsolateCount, 0);
      wg.shutdown();
    });

    test(
      'dispatch throws WorkgroupException synchronously '
      '(observed-and-locked: no send ports available)',
      () async {
        final wg = IsolateWorkgroup(0);
        await wg.launch();
        expect(
          () => wg.dispatch(EchoJob<int>(1)),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            contains('No send ports available'),
          )),
        );
        wg.shutdown();
      },
    );

    test(
      'sync dispatch throw does NOT leak an orphan completer '
      '(regression — previously caused unhandled async error on shutdown)',
      () async {
        // Wrap in a runZonedGuarded zone so we can detect any unhandled
        // async error that would otherwise be reported globally.
        final uncaught = <Object>[];
        await runZonedGuarded(() async {
          final wg = IsolateWorkgroup(0);
          await wg.launch();
          // Synchronous throw — orphan completer must be cleaned up.
          try {
            wg.dispatch(EchoJob<int>(1));
          } catch (_) {/* expected */}
          wg.shutdown();
          // Allow any pending microtasks to drain.
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }, (e, _) => uncaught.add(e));

        expect(uncaught, isEmpty,
            reason: 'sync-throw dispatch must not leak a completer that gets '
                'errored later by shutdown');
      },
    );
  });

  group('shutdown()', () {
    test(
      'pending dispatch fails with WorkgroupJobAbortedException',
      () async {
        final wg = IsolateWorkgroup(2);
        await wg.launch();

        final fut = wg.dispatch(SleepJob(2000, 'never'));
        // Give the job time to start.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        wg.shutdown();

        await expectLater(
          fut,
          throwsA(isA<WorkgroupJobAbortedException>()),
        );
      },
    );

    test(
      'clears state maps, closes ports, sets state = disposed',
      () async {
        final wg = IsolateWorkgroup(3);
        await wg.launch();
        wg.shutdown();

        expect(wg.state, WorkgroupState.disposed);
        expect(wg.mainReceivePorts, isEmpty);
        expect(wg.workerToMainSendPorts, isEmpty);
        expect(wg.mainToWorkerSendPorts, isEmpty);
        expectAllStateMapsEmpty(wg);
      },
    );

    test('post-shutdown dispatch throws WorkgroupInactiveException', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      wg.shutdown();
      expect(
        () => wg.dispatch(EchoJob<int>(1)),
        throwsA(isA<WorkgroupInactiveException>()),
      );
    });

    test('post-shutdown addInstance throws WorkgroupInactiveException',
        () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      wg.shutdown();
      await expectLater(
        wg.addInstance(_NoopMember()),
        throwsA(isA<WorkgroupInactiveException>()),
      );
    });

    test('post-shutdown kill throws WorkgroupInactiveException', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      wg.shutdown();
      expect(
        () => wg.kill(0),
        throwsA(isA<WorkgroupInactiveException>()),
      );
    });

    test('post-shutdown addIsolate throws WorkgroupException', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      wg.shutdown();
      await expectLater(
        wg.addIsolate(),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('shutdown is idempotent (calling twice is a no-op)', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      wg.shutdown();
      // Second call must not throw.
      wg.shutdown();
      expect(wg.state, WorkgroupState.disposed);
    });
  });

  group('labelBuilder', () {
    test(
      'produces expected debug names visible in errorReceivePortsStreamsMap',
      () async {
        final wg = IsolateWorkgroup(
          3,
          config: const WorkgroupConfig(labelBuilder: customLabel),
        );
        await wg.launch();

        final keys = wg.errorReceivePortsStreamsMap.keys.toSet();
        expect(
            keys,
            containsAll([
              'custom_worker_0',
              'custom_worker_1',
              'custom_worker_2',
            ]));

        // receivePortsStreamsMap uses the same debug names.
        final mainKeys = wg.receivePortsStreamsMap.keys.toSet();
        expect(
            mainKeys,
            containsAll([
              'custom_worker_0',
              'custom_worker_1',
              'custom_worker_2',
            ]));

        wg.shutdown();
      },
    );

    test('default labels are workgroup_worker_N', () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();
      final keys = wg.errorReceivePortsStreamsMap.keys.toSet();
      expect(keys, containsAll(['workgroup_worker_0', 'workgroup_worker_1']));
      wg.shutdown();
    });
  });

  group('repeated launch/shutdown cycles', () {
    test(
      '5 fresh instances launch + dispatch + shutdown without leaking '
      'observable state',
      () async {
        for (var cycle = 0; cycle < 5; cycle++) {
          final wg = IsolateWorkgroup(3);
          await wg.launch();
          final result = await wg.dispatch(AddJob(cycle, cycle));
          expect(result, cycle * 2);
          wg.shutdown();
          expect(wg.state, WorkgroupState.disposed);
          expectAllStateMapsEmpty(wg);
          // Yield so finalization runs between cycles.
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      },
    );
  });
}

// Minimal noop member fixture, kept in this file so
// _support/members.dart isn't imported just for one test.
class _NoopMember extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async => null;
}
