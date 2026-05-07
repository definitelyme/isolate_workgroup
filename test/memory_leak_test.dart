/// Memory-leak invariant probes + RSS sampling. Tagged `slow`.
/// Spec §7.14.
@TestOn('vm')
@Tags(['slow'])
library;

import 'dart:async';

// Internal import — required to read the worker-side `workerInstances`
// map from inside a probe job. This is a deliberate test-only escape
// hatch to verify the deeper invariant that the spec calls for.
// ignore: implementation_imports
import 'package:isolate_workgroup/src/internal/export.dart' as internal;
import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/commands.dart';
import '_support/jobs.dart';
import '_support/members.dart';
import '_support/probes.dart';

class _ProbeWorkerInstancesJob extends WorkgroupJob<int> {
  @override
  Future<int> execute() async => internal.workerInstances.length;
}

void throwingSetup() {
  throw StateError('mem-leak-onSetup-fail');
}

void main() {
  test(
    'after 1000 successful dispatches, pendingCount == 0 and _jobs empty',
    () async {
      final wg = IsolateWorkgroup(4);
      await wg.launch();
      final futures = <Future<int>>[];
      for (var i = 0; i < 1000; i++) {
        futures.add(wg.dispatch(EchoJob<int>(i)));
      }
      await Future.wait(futures);
      expect(wg.pendingCount, 0);
      expect(wg.requestCompleters, isEmpty);
      wg.shutdown();
    },
  );

  test(
    'after 100 add+destroy cycles: memberCount == 0 main-side AND '
    'workerInstances is empty isolate-side',
    () async {
      // Pin to a single isolate so the per-isolate workerInstances probe
      // is meaningful.
      final wg = IsolateWorkgroup(1);
      await wg.launch();

      for (var cycle = 0; cycle < 100; cycle++) {
        final p = await wg.addInstance(EchoMember(), isolateIndex: 0);
        wg.destroyInstance(p);
      }
      // Allow worker to process all destroy requests.
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(wg.memberCount, 0);
      final isolateSideCount = await wg.dispatch(_ProbeWorkerInstancesJob(), 0);
      expect(isolateSideCount, 0,
          reason: 'isolate-side workerInstances should also be empty');

      wg.shutdown();
    },
  );

  test(
    'after kill: that isolate is gone from health/_isolates and all '
    '3 port maps',
    () async {
      final wg = IsolateWorkgroup(3);
      await wg.launch();
      wg.kill(1);

      expectIsolatePortsRemoved(wg, 1);
      expect(wg.healthStatus.containsKey(1), isFalse);
      expect(wg.mainToWorkerSendPorts.containsKey(1), isFalse);

      wg.shutdown();
    },
  );

  test(
    'after shutdown: every public-facing map is empty and state is disposed',
    () async {
      final wg = IsolateWorkgroup(3);
      await wg.launch();
      // Add some load before shutdown.
      await wg.dispatch(EchoJob<int>(1));
      await wg.addInstance(EchoMember());
      wg.shutdown();

      expect(wg.state, WorkgroupState.disposed);
      expect(wg.mainReceivePorts, isEmpty);
      expect(wg.workerToMainSendPorts, isEmpty);
      expect(wg.mainToWorkerSendPorts, isEmpty);
      expect(wg.requestCompleters, isEmpty);
      expect(wg.pendingCount, 0);
    },
  );

  test(
    'after addIsolate with failing onSetup: rollback leaves state '
    'identical to pre-call',
    () async {
      final wg = IsolateWorkgroup(
        1,
        config: const WorkgroupConfig(onSetup: throwingSetup),
      );
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      // ignore: unawaited_futures
      wg.ready.catchError((Object _) {});
      await wg.launch();

      final beforeCount = wg.isolatesCount;
      final beforeLive = wg.liveIsolateCount;
      final beforePortKeys = wg.receivePortsStreamsMap.keys.toSet();

      await expectLater(
        wg.addIsolate(debugLabel: 'rollback-probe'),
        throwsA(isA<WorkgroupException>()),
      );

      // No port-map entry leaked for the failed index.
      final afterPortKeys = wg.receivePortsStreamsMap.keys.toSet();
      final newKeys = afterPortKeys.difference(beforePortKeys);
      expect(newKeys, isEmpty);
      expect(wg.isolatesCount, beforeCount);
      expect(wg.liveIsolateCount, beforeLive);

      wg.shutdown();
    },
  );

  test(
    'repeated launch/shutdown × 20: RSS delta stays within 50 MB budget',
    () async {
      await expectRssBudget(
        () async {
          for (var cycle = 0; cycle < 20; cycle++) {
            final wg = IsolateWorkgroup(2);
            await wg.launch();
            await wg.dispatch(EchoJob<int>(cycle));
            wg.shutdown();
          }
        },
        maxDeltaMb: 50,
      );
    },
  );

  test(
    'sustained 5000-dispatch run: RSS delta < 100 MB',
    () async {
      final wg = IsolateWorkgroup(4);
      await wg.launch();
      await expectRssBudget(
        () async {
          // Dispatch in batches so we don't blow up Future.wait's queue.
          for (var batch = 0; batch < 50; batch++) {
            final futs = <Future>[];
            for (var i = 0; i < 100; i++) {
              futs.add(wg.dispatch(EchoJob<int>(i)));
            }
            await Future.wait(futs);
          }
        },
        maxDeltaMb: 100,
      );
      wg.shutdown();
    },
  );

  test(
    'after invoke errors: requestCompleters drains',
    () async {
      final wg = IsolateWorkgroup(1);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();

      final p = await wg.addInstance(EchoMember());
      // Many errored invokes.
      final futures = <Future>[];
      for (var i = 0; i < 50; i++) {
        futures.add(p
            .invoke<dynamic>(ThrowCommand('err-$i'))
            .catchError((Object _) => null));
      }
      await Future.wait(futures);
      expect(wg.pendingCount, 0,
          reason: 'all errored invokes should clean up their completers');

      wg.shutdown();
    },
  );

  test(
    'after unsendable-job rejection: workgroup is still usable',
    () async {
      final wg = IsolateWorkgroup(2);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();

      // Issue an unsendable closure dispatch via a Repository pattern.
      final repo = _UnsendableRepo(wg);
      await expectLater(
        repo.dispatchDangerous(),
        throwsA(isA<WorkgroupException>()),
      );
      // Workgroup must still process subsequent dispatches.
      expect(await wg.dispatch(EchoJob<int>(11)), 11);
      expect(wg.pendingCount, 0);
      repo.dispose();

      wg.shutdown();
    },
  );

  test(
    'after kill() with requests in flight: request maps cleared',
    () async {
      final wg = IsolateWorkgroup(2);
      await wg.launch();

      final p = await wg.addInstance(EchoMember(), isolateIndex: 1);
      // Issue a slow invoke on isolate 1.
      final inflight = p.invoke<int>(SleepCommand(2000));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      wg.kill(1);

      await expectLater(inflight, throwsA(isA<WorkgroupException>()));
      // Request completers should be drained.
      expect(wg.requestCompleters, isEmpty);

      wg.shutdown();
    },
  );
}

// Top-level closure that captures a non-sendable from the repo's `this`.
class _UnsendableRepo {
  _UnsendableRepo(this.wg);
  final IsolateWorkgroup wg;
  // ignore: close_sinks
  final StreamController<int> _controller = StreamController<int>();

  Future<int> dispatchDangerous() {
    return wg.dispatch(_ParamsJob<int, int>(5, (i) {
      final hasL = _controller.hasListener;
      return i * 2 + (hasL ? 0 : 0);
    }));
  }

  void dispose() => _controller.close();
}

class _ParamsJob<P, R> extends WorkgroupJob<R> {
  _ParamsJob(this.param, this.handler);
  final P param;
  final R Function(P) handler;
  @override
  Future<R> execute() async => handler(param);
}
