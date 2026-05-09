/// Tests for [CallbackWorkgroup] / [CallbackWorkgroupJob].
/// Spec §7.11.
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/probes.dart';

class _AsyncReportingJob extends CallbackWorkgroupJob<int, int> {
  _AsyncReportingJob({required this.reportCount, required this.result})
      : super(false);
  final int reportCount;
  final int result;

  @override
  Future<int> executeAsync() async {
    for (var i = 0; i < reportCount; i++) {
      report(i);
    }
    return result;
  }

  @override
  int executeSync() => throw UnimplementedError();
}

class _SyncJob extends CallbackWorkgroupJob<int, int> {
  _SyncJob(this.value) : super(true);
  final int value;

  @override
  int executeSync() {
    report(value);
    return value * 10;
  }

  @override
  Future<int> executeAsync() async => throw UnimplementedError();
}

class _SlowAsyncJob extends CallbackWorkgroupJob<int, int> {
  _SlowAsyncJob(this.durationMs) : super(false);
  final int durationMs;

  @override
  Future<int> executeAsync() async {
    await Future<void>.delayed(Duration(milliseconds: durationMs));
    return 1;
  }

  @override
  int executeSync() => 1;
}

class _ThrowingAsyncJob extends CallbackWorkgroupJob<int, int> {
  _ThrowingAsyncJob(this.message) : super(false);
  final String message;

  @override
  Future<int> executeAsync() async {
    throw StateError(message);
  }

  @override
  int executeSync() => throw UnimplementedError();
}

void main() {
  group('happy paths', () {
    test('async: report() calls callback, result resolves', () async {
      final received = <int>[];
      final result = await CallbackWorkgroup(
        _AsyncReportingJob(reportCount: 3, result: 42),
      ).run((arg) => received.add(arg));
      expect(result, 42);
      expect(received, [0, 1, 2]);
    });

    test('sync: synchronous=true executes executeSync()', () async {
      final received = <int>[];
      final result =
          await CallbackWorkgroup(_SyncJob(7)).run((arg) => received.add(arg));
      expect(result, 70);
      expect(received, [7]);
    });

    test('many reports before final result are all delivered', () async {
      final received = <int>[];
      final result = await CallbackWorkgroup(
        _AsyncReportingJob(reportCount: 50, result: -1),
      ).run((arg) => received.add(arg));
      expect(result, -1);
      expect(received.length, 50);
      expect(received.first, 0);
      expect(received.last, 49);
    });
  });

  group('timeout', () {
    test(
      'caught: long job + short timeout → WorkgroupTimeoutException',
      () async {
        await expectLater(
          CallbackWorkgroup(_SlowAsyncJob(2000)).run(
            null,
            timeout: const Duration(milliseconds: 100),
          ),
          throwsA(isA<WorkgroupTimeoutException>()),
        );
      },
    );

    test(
      'unhandled: timeout error reaches runZonedGuarded zone',
      () async {
        final (err, _) = await captureUnhandled(() {
          // ignore: unawaited_futures
          CallbackWorkgroup(_SlowAsyncJob(2000)).run(
            null,
            timeout: const Duration(milliseconds: 100),
          );
        }, timeout: const Duration(seconds: 3));
        expect(err, isA<WorkgroupTimeoutException>());
      },
    );
  });

  group('error paths', () {
    test(
      'onError callback receives the error; '
      'the returned future does NOT complete (current behavior — locked in)',
      () async {
        Object? handlerErr;
        final caught = Completer<bool>();
        // Do not await run() — when onError is supplied, the returned
        // future is never completed (success OR failure) by the package.
        // ignore: unawaited_futures
        CallbackWorkgroup(_ThrowingAsyncJob('routed-to-onError')).run(
          null,
          onError: (e, _) {
            handlerErr = e;
            if (!caught.isCompleted) caught.complete(true);
          },
        );

        await caught.future.timeout(const Duration(seconds: 3));
        expect(handlerErr, isA<StateError>());
        expect((handlerErr as StateError).message, 'routed-to-onError');
      },
      // Bound the test more tightly than the suite default so a regression
      // (future never completes) doesn't burn 30 s.
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'caught: error propagates to Future when no onError provided',
      () async {
        await expectLater(
          CallbackWorkgroup(_ThrowingAsyncJob('to-future')).run(null),
          throwsA(isA<StateError>().having(
            (e) => e.message,
            'message',
            'to-future',
          )),
        );
      },
    );

    test(
      'unhandled: error reaches runZonedGuarded zone when no onError',
      () async {
        final (err, _) = await captureUnhandled(() {
          // ignore: unawaited_futures
          CallbackWorkgroup(_ThrowingAsyncJob('to-zone')).run(null);
        }, timeout: const Duration(seconds: 3));
        expect(err, isA<StateError>());
      },
    );

    test('exception type is preserved across the isolate boundary', () async {
      try {
        await CallbackWorkgroup(_ThrowingAsyncJob('preserve')).run(null);
        fail('expected throw');
      } catch (e) {
        expect(e, isA<StateError>());
        expect((e as StateError).message, 'preserve');
      }
    });
  });

  group('stack trace combining', () {
    test(
      'combineStackTraces=true produces both frames in the resulting trace',
      () async {
        try {
          await CallbackWorkgroup(_ThrowingAsyncJob('combine-on')).run(
            null,
            combineStackTraces: true,
          );
          fail('expected throw');
        } catch (_, st) {
          final s = st.toString();
          expect(s, contains('Stack trace in isolate'));
          expect(s, contains('Stack trace in main isolate'));
        }
      },
    );

    test(
      'combineStackTraces=false produces only the isolate-side trace',
      () async {
        try {
          await CallbackWorkgroup(_ThrowingAsyncJob('combine-off')).run(
            null,
            combineStackTraces: false,
          );
          fail('expected throw');
        } catch (_, st) {
          final s = st.toString();
          expect(
            s.contains('Stack trace in main isolate'),
            isFalse,
            reason: 'combineStackTraces=false must not produce combined frame',
          );
        }
      },
    );
  });

  group('isolation invariants', () {
    test(
      'errorsAreFatal=true does not crash the main isolate',
      () async {
        // Even with fatalErrors, the CallbackWorkgroup catches the throw
        // inside its isolate body and routes it to the error port.
        await expectLater(
          CallbackWorkgroup(_ThrowingAsyncJob('fatal-but-fine')).run(
            null,
            errorsAreFatal: true,
          ),
          throwsA(isA<StateError>()),
        );
        // Subsequent runs in fresh CallbackWorkgroups still work.
        final ok = await CallbackWorkgroup(_SyncJob(5)).run(null);
        expect(ok, 50);
      },
    );

    test(
      'multiple concurrent CallbackWorkgroup instances do not cross-talk',
      () async {
        final received = <String, List<int>>{
          'a': <int>[],
          'b': <int>[],
          'c': <int>[],
        };
        final futures = <Future<int>>[];
        for (final tag in ['a', 'b', 'c']) {
          futures.add(
            CallbackWorkgroup(_AsyncReportingJob(reportCount: 5, result: 0))
                .run((arg) => received[tag]!.add(arg)),
          );
        }
        await Future.wait(futures);
        for (final tag in ['a', 'b', 'c']) {
          expect(received[tag], [0, 1, 2, 3, 4]);
        }
      },
    );

    test(
      'debugName flows through to the isolate (smoke check)',
      () async {
        // Best-effort: just ensure run() with debugName doesn't break.
        final r = await CallbackWorkgroup(_SyncJob(3)).run(
          null,
          debugName: 'cb-debug-test',
        );
        expect(r, 30);
      },
    );
  });
}
