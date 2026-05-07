// Two minimal samples for isolate_workgroup.
//
//   Sample 1 — dispatch(): parallel one-off jobs.
//              Splits a big numeric range into chunks, computes a partial
//              sum in each worker, and reduces the partials in the main
//              isolate. Demonstrates fire-and-forget jobs whose result
//              you await.
//
//   Sample 2 — addInstance() + invoke(): stateful members.
//              Spawns a `Counter` member in each worker and drives it
//              with a small WorkerCommand vocabulary. Demonstrates
//              persistent state living inside a worker across many calls.

import 'package:isolate_workgroup/isolate_workgroup.dart';

void main(List<String> arguments) async {
  final workgroup = IsolateWorkgroup(4);
  await workgroup.launch();

  try {
    await sample1ParallelReduce(workgroup);
    await sample2StatefulCounters(workgroup);
  } finally {
    workgroup.shutdown();
  }
}

// ─── Sample 1: parallel reduce via dispatch() ────────────────────────────────

Future<void> sample1ParallelReduce(IsolateWorkgroup workgroup) async {
  print('\n=== Sample 1: parallel reduce ===');

  // Sum 1..N split across 4 chunks, reduced in main.
  const total = 1000000;
  const chunks = 4;
  const chunkSize = total ~/ chunks;

  final futures = <Future<ChunkStats>>[
    for (var i = 0; i < chunks; i++)
      workgroup.dispatch(
        SumChunkJob(start: i * chunkSize + 1, end: (i + 1) * chunkSize),
      ),
  ];

  final partials = await Future.wait(futures);
  final sum = partials.fold<int>(0, (acc, p) => acc + p.sum);
  final count = partials.fold<int>(0, (acc, p) => acc + p.count);
  print('Sum 1..$total = $sum  (count=$count, mean=${sum / count})');
}

/// A small sendable record returned from a chunk.
class ChunkStats {
  final int sum;
  final int count;
  const ChunkStats(this.sum, this.count);
}

/// Pure-data job: only sendable fields, executes in a worker.
class SumChunkJob extends WorkgroupJob<ChunkStats> {
  final int start;
  final int end;
  const SumChunkJob({required this.start, required this.end});

  @override
  Future<ChunkStats> execute() async {
    var s = 0;
    for (var i = start; i <= end; i++) {
      s += i;
    }
    return ChunkStats(s, end - start + 1);
  }
}

// ─── Sample 2: stateful Counter members via addInstance() ────────────────────

Future<void> sample2StatefulCounters(IsolateWorkgroup workgroup) async {
  print('\n=== Sample 2: stateful Counters ===');

  // One Counter per worker. Each holds independent state in its isolate.
  final counters = <MemberProxy>[
    for (var i = 0; i < 4; i++)
      await workgroup.addInstance(Counter(), isolateIndex: i),
  ];

  // Seed each counter with a different starting amount.
  for (var i = 0; i < counters.length; i++) {
    await counters[i].invoke(IncrementBy((i + 1) * 10));
  }

  for (var i = 0; i < counters.length; i++) {
    final value = await counters[i].invoke<int>(GetValue());
    print('Worker $i counter starts at $value');
  }

  // Drive counter 0 through 100 increments to show state persists across calls.
  for (var i = 0; i < 100; i++) {
    await counters[0].invoke(IncrementBy(1));
  }
  final finalValue = await counters[0].invoke<int>(GetValue());
  print('Worker 0 after +100 increments: $finalValue');

  // Reset + verify.
  await counters[0].invoke(Reset());
  print('Worker 0 after reset: ${await counters[0].invoke<int>(GetValue())}');

  // Always destroy members you added.
  for (final c in counters) {
    workgroup.destroyInstance(c);
  }
}

// Commands the Counter understands. WorkerCommand fields must be sendable.
class IncrementBy extends WorkerCommand {
  final int amount;
  IncrementBy(this.amount);
}

class GetValue extends WorkerCommand {}

class Reset extends WorkerCommand {}

/// Persistent state that lives inside a worker isolate. The `Counter`
/// instance is sent to the worker once on addInstance(); subsequent
/// invoke() calls run handle() inside the worker.
class Counter extends WorkgroupMember {
  int _value = 0;

  @override
  Future<void> setup() async {
    // Initialize resources here if needed.
  }

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    switch (command) {
      case IncrementBy():
        _value += command.amount;
        return null;
      case GetValue():
        return _value;
      case Reset():
        _value = 0;
        return null;
      default:
        throw ArgumentError('Unknown command: ${command.runtimeType}');
    }
  }
}
