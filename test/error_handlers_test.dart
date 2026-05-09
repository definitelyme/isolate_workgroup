/// Error-handler routing + errorsAreFatal interaction tests.
/// Spec §7.9 — sub-sections A (routing), B (fatal interaction),
/// C (paired propagation).
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';
import '_support/probes.dart';

// Top-level setup that schedules a Timer.zero that throws — the throw
// escapes the worker body's try/catch and reaches the builtin onError
// port as [errorString, stackString] (Dart 2026 semantics, spec §5).
void escapingSetup() {
  Timer(Duration.zero, () {
    throw 'escaped-boom';
  });
}

void main() {
  group('A — handler routing', () {
    test(
      'IsolateErrorType.job handler fires on job error',
      () async {
        Object? jobErr;
        final wg = IsolateWorkgroup(1);
        wg.setErrorHandler(IsolateErrorType.job, (e) => jobErr = e);
        await wg.launch();

        await expectLater(
          wg.dispatch(ThrowJob('jb')),
          throwsA(isA<Exception>()),
        );
        // Error handler is fired async via the error port; allow it a tick.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(jobErr, isNotNull);

        wg.shutdown();
      },
    );

    test(
      'specific handler beats IsolateErrorType.all',
      () async {
        Object? jobHits;
        Object? allHits;
        final wg = IsolateWorkgroup(1);
        wg.setErrorHandler(IsolateErrorType.job, (e) => jobHits = e);
        wg.setErrorHandler(IsolateErrorType.all, (e) => allHits = e);
        await wg.launch();

        await expectLater(
          wg.dispatch(ThrowJob('only-job')),
          throwsA(isA<Exception>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(jobHits, isNotNull, reason: 'specific .job handler must fire');
        expect(allHits, isNull,
            reason: '.all must NOT also fire when .job is registered');

        wg.shutdown();
      },
    );

    test(
      'IsolateErrorType.all fires when no specific handler matches',
      () async {
        Object? allHits;
        final wg = IsolateWorkgroup(1);
        wg.setErrorHandler(IsolateErrorType.all, (e) => allHits = e);
        await wg.launch();

        await expectLater(
          wg.dispatch(ThrowJob('hits-all')),
          throwsA(isA<Exception>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(allHits, isNotNull);

        wg.shutdown();
      },
    );

    test('removeErrorHandler removes only that type', () async {
      var jobCalls = 0;
      var allCalls = 0;
      final wg = IsolateWorkgroup(1);
      wg.setErrorHandler(IsolateErrorType.job, (_) => jobCalls++);
      wg.setErrorHandler(IsolateErrorType.all, (_) => allCalls++);
      await wg.launch();

      await expectLater(
        wg.dispatch(ThrowJob('first')),
        throwsA(isA<Exception>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(jobCalls, 1);

      wg.removeErrorHandler(IsolateErrorType.job);

      await expectLater(
        wg.dispatch(ThrowJob('second')),
        throwsA(isA<Exception>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // .job is gone; .all picks up the next.
      expect(jobCalls, 1, reason: '.job handler removed');
      expect(allCalls, 1, reason: '.all handler is now the fallback');

      wg.shutdown();
    });

    test('clearErrorHandlers removes all handlers', () async {
      var anyCalls = 0;
      final wg = IsolateWorkgroup(1);
      wg.setErrorHandler(IsolateErrorType.job, (_) => anyCalls++);
      wg.setErrorHandler(IsolateErrorType.all, (_) => anyCalls++);
      await wg.launch();

      wg.clearErrorHandlers();

      await expectLater(
        wg.dispatch(ThrowJob('cleared')),
        throwsA(isA<Exception>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(anyCalls, 0,
          reason: 'no handlers should fire after clearErrorHandlers');

      wg.shutdown();
    });

    test(
      'a handler that itself throws does not break the workgroup',
      () async {
        var secondJobOk = false;
        final wg = IsolateWorkgroup(1);
        wg.setErrorHandler(IsolateErrorType.job, (_) {
          throw StateError('handler-itself-blew-up');
        });
        await wg.launch();

        // First throwing job — handler will throw too.
        await expectLater(
          wg.dispatch(ThrowJob('first')),
          throwsA(isA<Exception>()),
        );

        // The workgroup should still process subsequent jobs.
        final result = await wg.dispatch(EchoJob<int>(99));
        expect(result, 99);
        secondJobOk = true;
        expect(secondJobOk, isTrue);

        wg.shutdown();
      },
    );

    test(
      'real-world pattern: .job + .all coexist, .job claims job errors',
      () async {
        var jobCount = 0;
        var allCount = 0;
        final wg = IsolateWorkgroup(1);
        wg.setErrorHandler(IsolateErrorType.job, (_) => jobCount++);
        wg.setErrorHandler(IsolateErrorType.all, (_) => allCount++);
        await wg.launch();

        // Job error → .job
        await expectLater(
          wg.dispatch(ThrowJob('hello')),
          throwsA(isA<Exception>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(jobCount, 1);
        // .all NOT called for a covered category.
        expect(allCount, 0);

        wg.shutdown();
      },
    );
  });

  group('B — errorsAreFatal interaction', () {
    test(
      'sealed path: fatalErrors: true + throw inside execute() → '
      'isolate stays alive (caught by package)',
      () async {
        final wg = IsolateWorkgroup(
          1,
          config: const WorkgroupConfig(fatalErrors: true),
        );
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        await wg.launch();
        expect(wg.liveIsolateCount, 1);

        await expectLater(
          wg.dispatch(ThrowJob('sealed')),
          throwsA(isA<Exception>()),
        );

        // Isolate is still alive; subsequent dispatch succeeds.
        final ok = await wg.dispatch(EchoJob<int>(7), 0);
        expect(ok, 7);
        expect(wg.liveIsolateCount, 1);

        wg.shutdown();
      },
    );

    test(
      'escaped path, fatal=false: Timer throw → reaches handler as '
      'List<String> of length 2; isolate stays alive',
      () async {
        final received = Completer<Object>();
        final wg = IsolateWorkgroup(
          1,
          config: const WorkgroupConfig(
            fatalErrors: false,
            onSetup: escapingSetup,
          ),
        );
        wg.setErrorHandler(IsolateErrorType.unknown, (e) {
          if (!received.isCompleted) received.complete(e);
        });
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        await wg.launch();

        final err = await received.future.timeout(const Duration(seconds: 3));

        // Shape contract: List<String> of length 2 (spec §5).
        expect(err, isA<List>());
        final list = err as List;
        expect(list.length, 2);
        expect(list[0], isA<String>());
        expect(list[1], isA<String>());
        expect(list[0] as String, contains('escaped-boom'));
        // err[1] is a stringified stack trace; StackTrace.fromString
        // accepts any string and produces a StackTrace.
        final st = StackTrace.fromString(list[1] as String);
        expect(st, isA<StackTrace>());

        // Isolate is still alive; subsequent dispatch succeeds.
        final ok = await wg.dispatch(EchoJob<int>(11));
        expect(ok, 11);

        wg.shutdown();
      },
    );

    test(
      'IsolateErrorType.unknown classification: [String, String] arrivals '
      'route to .unknown when registered',
      () async {
        final unknownErrors = <Object>[];
        final wg = IsolateWorkgroup(
          1,
          config: const WorkgroupConfig(
            fatalErrors: false,
            onSetup: escapingSetup,
          ),
        );
        wg.setErrorHandler(IsolateErrorType.unknown, unknownErrors.add);
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        await wg.launch();

        // Wait for the timer-escape to fire and propagate.
        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(unknownErrors, isNotEmpty);
        expect(unknownErrors.first, isA<List>());

        wg.shutdown();
      },
    );

    test(
      '[String, String] without .unknown registered falls through to .all',
      () async {
        final allErrors = <Object>[];
        final wg = IsolateWorkgroup(
          1,
          config: const WorkgroupConfig(
            fatalErrors: false,
            onSetup: escapingSetup,
          ),
        );
        wg.setErrorHandler(IsolateErrorType.all, allErrors.add);
        await wg.launch();

        await Future<void>.delayed(const Duration(milliseconds: 200));
        expect(allErrors, isNotEmpty);
        expect(allErrors.first, isA<List>());

        wg.shutdown();
      },
    );
  });

  group('C — paired propagation', () {
    test(
      'caught: handler fires AND awaiting future receives the error',
      () async {
        Object? handlerErr;
        final wg = IsolateWorkgroup(1);
        wg.setErrorHandler(IsolateErrorType.job, (e) => handlerErr = e);
        await wg.launch();

        Object? futureErr;
        try {
          await wg.dispatch(ThrowJob('paired'));
        } catch (e) {
          futureErr = e;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(futureErr, isNotNull,
            reason: 'awaiting future receives the error');
        expect(handlerErr, isNotNull, reason: 'handler also fires');

        wg.shutdown();
      },
    );

    test(
      'unhandled: dispatch error reaches runZonedGuarded zone',
      () async {
        final wg = IsolateWorkgroup(1);
        wg.setErrorHandler(IsolateErrorType.all, (_) {});
        await wg.launch();

        final (err, _) = await captureUnhandled(() {
          // ignore: unawaited_futures
          wg.dispatch(ThrowJob('zone-paired'));
        });
        expect(err.toString(), contains('zone-paired'));

        wg.shutdown();
      },
    );
  });
}
