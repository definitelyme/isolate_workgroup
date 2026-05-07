/// dispatch() routing, queueing, error propagation tests.
/// Spec §7.3 — paired caught + unhandled error variants.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';
import '_support/probes.dart';

// Job that captures a non-sendable closure via its constructor.
class ClosureCapturingJob extends WorkgroupJob<int> {
  ClosureCapturingJob(this.x, this.f);
  final int x;
  final int Function(int) f;

  @override
  Future<int> execute() async => f(x);
}

// Repository that holds a non-sendable StreamController and exposes a
// dispatch helper whose closure captures `this` (mirrors the proven
// real-world capture pattern from the original validation suite).
class _ClosureRepo {
  _ClosureRepo(this.wg);
  final IsolateWorkgroup wg;
  // ignore: close_sinks
  final StreamController<int> _controller = StreamController<int>();

  Future<int> dispatchDangerous(int x) {
    return wg.dispatch(
      ClosureCapturingJob(x, (i) {
        // Forces capture of `this`, which carries _controller.
        final hasL = _controller.hasListener;
        return i * 2 + (hasL ? 0 : 0);
      }),
    );
  }

  // Fire-and-forget close; awaiting can hang when the stream has no
  // listener and the controller's state was perturbed by a failed send.
  void dispose() {
    _controller.close();
  }
}

void main() {
  group('happy paths', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(4);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test('sync-result job returns expected value', () async {
      final result = await wg.dispatch(EchoJob<int>(42));
      expect(result, 42);
    });

    test('async-result job returns expected value', () async {
      final result = await wg.dispatch(SleepJob(20, 'done'));
      expect(result, 'done');
    });

    test('many concurrent dispatches > worker count all complete', () async {
      final futures = <Future<int>>[];
      for (var i = 0; i < 32; i++) {
        futures.add(wg.dispatch(AddJob(i, 1)));
      }
      final results = await Future.wait(futures);
      for (var i = 0; i < 32; i++) {
        expect(results[i], i + 1);
      }
    });

    test('null result is preserved', () async {
      final result = await wg.dispatch(NullJob());
      expect(result, isNull);
    });

    test('void-typed jobs complete without error', () async {
      await wg.dispatch(VoidJob()); // should not throw
    });

    test(
      'TransferableTypedData round-trip (large binary)',
      () async {
        final bytes = Uint8List(32 * 1024); // 32 KB
        for (var i = 0; i < bytes.length; i++) {
          bytes[i] = i & 0xff;
        }
        var expectedSum = 0;
        for (final b in bytes) {
          expectedSum += b;
        }
        final ttd = TransferableTypedData.fromList([bytes]);
        final result = await wg.dispatch(TransferableJob(ttd));
        expect(result, expectedSum);
      },
    );
  });

  group('isolateIndex routing', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(3);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test('isolateIndex = -1 round-robins onto an alive isolate', () async {
      // Just verify all three indices accept work.
      for (var i = 0; i < 3; i++) {
        final r = await wg.dispatch(EchoJob<int>(i), -1);
        expect(r, i);
      }
    });

    test('explicit isolateIndex routes the job', () async {
      final r0 = await wg.dispatch(EchoJob<int>(100), 0);
      final r1 = await wg.dispatch(EchoJob<int>(200), 1);
      final r2 = await wg.dispatch(EchoJob<int>(300), 2);
      expect([r0, r1, r2], [100, 200, 300]);
    });

    test('out-of-range isolateIndex throws WorkgroupException', () {
      expect(
        () => wg.dispatch(EchoJob<int>(1), 99),
        throwsA(isA<WorkgroupException>()),
      );
      expect(
        () => wg.dispatch(EchoJob<int>(1), -2),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('killed-isolate index throws WorkgroupException', () {
      wg.kill(1);
      expect(
        () => wg.dispatch(EchoJob<int>(1), 1),
        throwsA(isA<WorkgroupException>().having(
          (e) => e.message,
          'message',
          contains('killed'),
        )),
      );
    });
  });

  group('error paths', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(2);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test(
      'caught: error inside execute() rejects the dispatch future',
      () async {
        await expectLater(
          wg.dispatch(ThrowJob('boom')),
          throwsA(isA<Exception>().having(
            (e) => e.toString(),
            'toString()',
            contains('boom'),
          )),
        );
      },
    );

    test(
      'unhandled: error inside execute() reaches a runZonedGuarded zone',
      () async {
        final (err, _) = await captureUnhandled(() {
          // Do not await — let the error propagate as unhandled.
          // ignore: unawaited_futures
          wg.dispatch(ThrowJob('boom-unhandled'));
        });
        expect(err.toString(), contains('boom-unhandled'));
      },
    );

    test(
      'WorkgroupIsolateError combined stack trace contains both frames',
      () async {
        try {
          await wg.dispatch(ThrowJob('combined'));
          fail('Expected throw');
        } catch (_, st) {
          final s = st.toString();
          expect(s, contains('Stack trace in isolate'));
          expect(s, contains('Stack trace in main isolate'));
        }
      },
    );

    test(
      'caught: closure that captures non-sendable object → '
      'WorkgroupException with canonical guidance',
      () async {
        final repo = _ClosureRepo(wg);
        await expectLater(
          repo.dispatchDangerous(5),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('non-sendable'),
              contains('static or top-level'),
            ),
          )),
        );
        repo.dispose();
      },
    );

    test(
      'unhandled: non-sendable closure error reaches runZonedGuarded zone',
      () async {
        final repo = _ClosureRepo(wg);
        final (err, _) = await captureUnhandled(() {
          // ignore: unawaited_futures
          repo.dispatchDangerous(5);
        });
        expect(err, isA<WorkgroupException>());
        expect((err as WorkgroupException).message, contains('non-sendable'));
        repo.dispose();
      },
    );

    test('workgroup remains usable after a failed dispatch', () async {
      await expectLater(
        wg.dispatch(ThrowJob('still alive?')),
        throwsA(isA<Exception>()),
      );
      // Subsequent dispatch must still succeed.
      final ok = await wg.dispatch(EchoJob<int>(7));
      expect(ok, 7);
    });
  });

  group('queueing semantics', () {
    test(
      '_lastJobStartedIndex uniqueness across many cycles '
      '(no completer collision)',
      () async {
        final wg = IsolateWorkgroup(2);
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        await wg.launch();

        // Run 200 dispatches across alternating success / failure to churn
        // the job-index counter. Any collision in completer keys would
        // manifest as wrong results or test hangs.
        final futures = <Future<dynamic>>[];
        for (var i = 0; i < 200; i++) {
          if (i.isEven) {
            futures.add(wg.dispatch(AddJob(i, 1)));
          } else {
            futures.add(wg
                .dispatch(ThrowJob('err-$i'))
                .catchError((Object _) => -1));
          }
        }
        final results = await Future.wait(futures);
        for (var i = 0; i < 200; i++) {
          if (i.isEven) {
            expect(results[i], i + 1);
          } else {
            expect(results[i], -1);
          }
        }
        // Pending should drain.
        expect(wg.pendingCount, 0);
        wg.shutdown();
      },
    );
  });
}
