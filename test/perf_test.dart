/// Informational performance benchmarks. Tagged `perf`; excluded from
/// default and `slow` runs. Spec §7.16.
///
/// All assertions are deliberately loose — these tests log timings and
/// only fail on order-of-magnitude regressions.
@TestOn('vm')
@Tags(['perf'])
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/commands.dart';
import '_support/jobs.dart';
import '_support/members.dart';

int _median(List<int> xs) {
  final sorted = [...xs]..sort();
  return sorted[sorted.length ~/ 2];
}

void main() {
  test('median dispatch round-trip across 100 trivial jobs', () async {
    final wg = IsolateWorkgroup(4);
    await wg.launch();
    final samples = <int>[];
    for (var i = 0; i < 100; i++) {
      final sw = Stopwatch()..start();
      await wg.dispatch(EchoJob<int>(i));
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    final medianUs = _median(samples);
    // ignore: avoid_print
    print('[perf] median dispatch round-trip: ${medianUs}us');
    // Loose: < 500 ms per call (very generous; informational).
    expect(medianUs, lessThan(500 * 1000));
    wg.shutdown();
  });

  test('median invoke round-trip across 100 calls', () async {
    final wg = IsolateWorkgroup(4);
    await wg.launch();
    final p = await wg.addInstance(EchoMember());
    final samples = <int>[];
    for (var i = 0; i < 100; i++) {
      final sw = Stopwatch()..start();
      await p.invoke<int>(EchoCommand<int>(i));
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    final medianUs = _median(samples);
    // ignore: avoid_print
    print('[perf] median invoke round-trip: ${medianUs}us');
    expect(medianUs, lessThan(500 * 1000));
    wg.shutdown();
  });

  test('parallel speedup: 4 CPU-bound jobs on 4 workers', () async {
    // Single-job baseline.
    final wg1 = IsolateWorkgroup(1);
    await wg1.launch();
    final swSingle = Stopwatch()..start();
    await wg1.dispatch(CpuBoundJob(40));
    swSingle.stop();
    wg1.shutdown();
    final singleMs = swSingle.elapsedMilliseconds;

    // Parallel.
    final wg4 = IsolateWorkgroup(4);
    await wg4.launch();
    final swPar = Stopwatch()..start();
    await Future.wait([
      wg4.dispatch(CpuBoundJob(40), 0),
      wg4.dispatch(CpuBoundJob(40), 1),
      wg4.dispatch(CpuBoundJob(40), 2),
      wg4.dispatch(CpuBoundJob(40), 3),
    ]);
    swPar.stop();
    wg4.shutdown();
    final parMs = swPar.elapsedMilliseconds;

    // ignore: avoid_print
    print('[perf] CpuBoundJob single=${singleMs}ms parallel=${parMs}ms '
        '(ratio ${(parMs / (singleMs == 0 ? 1 : singleMs)).toStringAsFixed(2)})');

    // Loose: parallel wall < 1.5× single. Skip if singleMs is too small
    // for a meaningful comparison.
    if (singleMs >= 5) {
      expect(parMs, lessThan(singleMs * 1.5 + 200),
          reason: 'parallel wall should be near single-task wall');
    }
  });

  test('TransferableTypedData throughput (informational)', () async {
    final wg = IsolateWorkgroup(2);
    await wg.launch();
    final bytes = Uint8List(64 * 1024); // 64 KB
    for (var i = 0; i < bytes.length; i++) {
      bytes[i] = i & 0xff;
    }
    final sw = Stopwatch()..start();
    for (var i = 0; i < 50; i++) {
      final ttd = TransferableTypedData.fromList([bytes]);
      await wg.dispatch(TransferableJob(ttd));
    }
    sw.stop();
    final mbPerSec =
        (50 * bytes.length) / (sw.elapsedMilliseconds / 1000) / (1024 * 1024);
    // ignore: avoid_print
    print('[perf] TransferableTypedData throughput: '
        '${mbPerSec.toStringAsFixed(2)} MB/s');
    wg.shutdown();
  });

  test('fan-out via sendPorts direct (informational)', () async {
    final wg = IsolateWorkgroup(4);
    await wg.launch();
    // Direct fan-out: send via sendPorts list and gather replies via
    // receivePortsStreamsMap. Mirrors scheduleJobToAll.
    final sw = Stopwatch()..start();
    // We just dispatch one trivial job per isolate via the public dispatch
    // API to simulate fan-out. The point of this test is to log latency.
    await Future.wait(List.generate(
      wg.sendPorts.length,
      (i) => wg.dispatch(EchoJob<int>(i), i),
    ));
    sw.stop();
    // ignore: avoid_print
    print('[perf] fan-out (4 workers): ${sw.elapsedMicroseconds}us');
    wg.shutdown();
  });
}
