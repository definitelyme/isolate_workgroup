/// Subprocess exit-timing tests. Tagged `slow`.
///
/// Triages possible-test-cases.txt issue #1 automatically: produces a
/// clear pass/fail signal for the documented `~25 s shutdown hang`,
/// regardless of which path hangs.
@TestOn('vm')
@Tags(['slow'])
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

/// Runs [scriptPath] as a subprocess (`dart run …`), waits up to [timeout],
/// and returns observed elapsed time. If the process doesn't exit within
/// [timeout], it is killed and the function still returns the elapsed
/// timeout duration (the `exited` flag distinguishes).
Future<({Duration elapsed, bool exited, int exitCode})> _timeSubprocess(
  String scriptPath, {
  required Duration timeout,
}) async {
  final sw = Stopwatch()..start();
  final proc = await Process.start(
    Platform.resolvedExecutable,
    ['run', scriptPath],
    workingDirectory: Directory.current.path,
  );

  final exitCodeFuture = proc.exitCode;
  // Drain stdout / stderr so the process buffer doesn't block.
  proc.stdout.listen((_) {});
  proc.stderr.listen((_) {});

  try {
    final code = await exitCodeFuture.timeout(timeout);
    sw.stop();
    return (elapsed: sw.elapsed, exited: true, exitCode: code);
  } on TimeoutException {
    sw.stop();
    proc.kill(ProcessSignal.sigkill);
    return (elapsed: sw.elapsed, exited: false, exitCode: -1);
  }
}

void main() {
  test(
    'minimal launch+shutdown subprocess exits in < 5 s',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final result = await _timeSubprocess(
        'test/_support/subprocess_targets/minimal_launch_shutdown.dart',
        timeout: const Duration(seconds: 30),
      );
      // Always print observed timing for triage.
      // ignore: avoid_print
      print(
        '[subprocess_exit_test] minimal_launch_shutdown: '
        'exited=${result.exited}, elapsed=${result.elapsed.inMilliseconds}ms, '
        'exitCode=${result.exitCode}',
      );
      expect(result.exited, isTrue,
          reason: 'minimal subprocess should exit, not hang');
      expect(result.elapsed.inSeconds, lessThan(5),
          reason:
              'minimal launch+shutdown should exit fast (got ${result.elapsed.inMilliseconds}ms)');
      expect(result.exitCode, 0);
    },
  );

  test(
    'subprocess with members exits in < 10 s',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final result = await _timeSubprocess(
        'test/_support/subprocess_targets/with_members.dart',
        timeout: const Duration(seconds: 30),
      );
      // ignore: avoid_print
      print(
        '[subprocess_exit_test] with_members: '
        'exited=${result.exited}, elapsed=${result.elapsed.inMilliseconds}ms, '
        'exitCode=${result.exitCode}',
      );
      expect(result.exited, isTrue,
          reason: 'subprocess should exit, not hang');
      expect(result.elapsed.inSeconds, lessThan(10),
          reason:
              'subprocess with members should exit < 10 s (got ${result.elapsed.inMilliseconds}ms)');
      expect(result.exitCode, 0);
    },
  );

  test(
    'example/example.dart exits in < 30 s '
    '(triages possible-test-cases.txt issue #1)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final result = await _timeSubprocess(
        'example/example.dart',
        timeout: const Duration(seconds: 30),
      );
      // Always print observed timing.
      // ignore: avoid_print
      print(
        '[subprocess_exit_test] example/example.dart: '
        'exited=${result.exited}, elapsed=${result.elapsed.inMilliseconds}ms, '
        'exitCode=${result.exitCode}',
      );
      // Pass if it exits within 30s; otherwise the documented hang is
      // reproduced and we fail with full timing context.
      expect(
        result.exited,
        isTrue,
        reason:
            'example/example.dart did not exit within 30 s '
            '— documented `~25 s shutdown hang` reproduced. '
            'See docs/superpowers/possible-test-cases.txt §1.',
      );
    },
  );
}
