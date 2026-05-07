/// Invariant probes, RSS sampling, and zone helpers used by leak / stress
/// tests. Spec §6 / §7.1 / §7.14.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

/// Asserts that all main-side state maps the workgroup exposes are empty.
/// Used after shutdown / drain cycles to catch leaks of jobs, members,
/// pending requests, or ports.
void expectAllStateMapsEmpty(IsolateWorkgroup wg) {
  expect(wg.pendingCount, 0, reason: 'pendingCount should be 0');
  expect(wg.memberCount, 0, reason: 'memberCount should be 0');
  expect(wg.requestCompleters, isEmpty, reason: 'requestCompleters should be empty');
  expect(wg.members, isEmpty, reason: 'members should be empty');
}

/// Asserts that the named isolate's debug name is gone from all 3 port maps,
/// after a kill().
void expectIsolatePortsRemoved(IsolateWorkgroup wg, int isolateIndex) {
  final receivePortKeys = wg.receivePortsStreamsMap.keys
      .where((k) => k.endsWith('$isolateIndex'))
      .toList();
  expect(
    receivePortKeys,
    isEmpty,
    reason: 'receivePortsStreamsMap should not contain ports for killed isolate $isolateIndex (found: $receivePortKeys)',
  );

  final errorPortKeys = wg.errorReceivePortsStreamsMap.keys
      .where((k) => k.endsWith('$isolateIndex'))
      .toList();
  expect(
    errorPortKeys,
    isEmpty,
    reason: 'errorReceivePortsStreamsMap should not contain ports for killed isolate $isolateIndex (found: $errorPortKeys)',
  );

  final w2mKeys = wg.workerToMainSendPorts.keys
      .where((k) => k.endsWith('$isolateIndex'))
      .toList();
  expect(
    w2mKeys,
    isEmpty,
    reason: 'workerToMainSendPorts should not contain entries for killed isolate $isolateIndex (found: $w2mKeys)',
  );

  expect(
    wg.mainToWorkerSendPorts.containsKey(isolateIndex),
    isFalse,
    reason: 'mainToWorkerSendPorts should not contain killed index $isolateIndex',
  );
}

/// Returns the current process RSS in megabytes (rounded down).
int sampleRssMb() {
  return ProcessInfo.currentRss ~/ (1024 * 1024);
}

/// Runs [fn], measures RSS delta, and asserts the process didn't grow by more
/// than [maxDeltaMb]. Triggers a forced GC pause via Future.delayed before
/// each measurement to give finalization a chance to settle.
///
/// Note: RSS sampling is platform-sensitive; budgets should be generous
/// (order-of-magnitude leak detection only — spec §9).
Future<void> expectRssBudget(
  Future<void> Function() fn, {
  required int maxDeltaMb,
  String? reason,
}) async {
  // Settle before measuring baseline.
  await Future<void>.delayed(const Duration(milliseconds: 50));
  final before = sampleRssMb();

  await fn();

  // Settle after work to let isolates clean up.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  final after = sampleRssMb();

  final delta = after - before;
  expect(
    delta,
    lessThanOrEqualTo(maxDeltaMb),
    reason: reason ??
        'RSS grew by ${delta}MB (before=${before}MB, after=${after}MB), '
            'budget was ${maxDeltaMb}MB',
  );
}

/// Wraps [fn] in a [runZonedGuarded] error zone and returns the first
/// (error, stackTrace) tuple captured by the zone, or completes with an
/// error if no uncaught error reaches the zone within [timeout].
///
/// This is how we test the "unhandled" variant of error paths: we run the
/// scenario inside a zone, omit `await` (or use a Future without a catch),
/// and verify the error reaches the zone as truly unhandled.
Future<(Object error, StackTrace stack)> captureUnhandled(
  void Function() fn, {
  Duration timeout = const Duration(seconds: 5),
}) {
  final completer = Completer<(Object, StackTrace)>();
  runZonedGuarded(
    fn,
    (e, st) {
      if (!completer.isCompleted) {
        completer.complete((e, st));
      }
    },
  );
  return completer.future.timeout(
    timeout,
    onTimeout: () => throw TimeoutException(
      'No uncaught error reached the zone within ${timeout.inMilliseconds}ms',
    ),
  );
}
