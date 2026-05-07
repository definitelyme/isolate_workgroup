import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:isolate_workgroup/isolate_workgroup.dart';

void main(List<String> arguments) async {
  // Start and await for the workgroup to finish launching
  var workgroup = IsolateWorkgroup(4);
  await workgroup.launch();

  // SAMPLE 1, Workgroup Job
  await multiplierJobs(workgroup);

  // SAMPLE 2, Workgroup Member
  await randomViaWorkgroupMembers(workgroup);

  // Shut the workgroup down and let the process finish
  workgroup.shutdown();
}

////////////////////////////
// SAMPLE 1, WorkgroupJob<T> //
////////////////////////////

Future<void> multiplierJobs(IsolateWorkgroup workgroup) async {
  print('\n\nEXAMPLE1\n');
  var futures = <Future<int>>[];
  // Dispatch multiple jobs to the workgroup and store all returned futures
  for (var i = 0; i < 15; i++) {
    futures.add(workgroup.dispatch<int>(DoubleNumbersJob(101 + i)));
  }

  // Wait for all futures to complete and collect the results
  var sum = (await Future.wait<int>(futures)).fold(0, (p, c) => p + c);
  print('Multiplication result: $sum');
}

// `DoubleNumbersJob` class inherits `WorkgroupJob` and implements an operation to be executed in the workgroup.
// In this case we do multiplication in `execute()` method that is overriden.
// `T` in `WorkgroupJob<T>` defines the result type returned by `execute()`, it is `int` here
class DoubleNumbersJob extends WorkgroupJob<int> {
  final int number;

  DoubleNumbersJob(this.number);

  @override
  Future<int> execute() async {
    print('DoubleNumbersJob: $number');
    return number * 2;
  }
}

//////////////////////////////
// SAMPLE 2, WorkgroupMember //
//////////////////////////////

Future<void> randomViaWorkgroupMembers(IsolateWorkgroup workgroup) async {
  print('\n\nEXAMPLE2\n');
  var proxies = List<MemberProxy>.empty(growable: true);

  // Create workgroup members inside the workers, collecting proxy objects to
  // communicate with them from the main isolate
  for (var i = 0; i < 4; i++) {
    proxies.add(await workgroup.addInstance(RandomBytesGenerator()));
  }

  // Call remote methods via proxies
  var futures = List<Future<RandomBytes>>.generate(proxies.length,
      (i) => proxies[i].invoke(GetNBytesAction(1024 * 1024)));

  // Await for remote method results
  var results = await Future.wait(futures);
  for (var r in results) {
    print('Min: ${r.min}, Max: ${r.max}, Avg: ${r.avg.toStringAsFixed(1)},');
  }

  // Repeating stats computation by trnasferig to isolaes bytes
  print('Recalculating stats');
  var i = 0;
  futures = results
      .map((r) =>
          proxies[i++].invoke<RandomBytes>(ComputeStats(r.bytes)))
      .toList();

  results = await Future.wait(futures);
  for (var r in results) {
    print('Min: ${r.min}, Max: ${r.max}, Avg: ${r.avg.toStringAsFixed(1)},');
  }
}

// WorkgroupMember implementation that will run all operations outside main isolate.
// Generating random numbers (which can be slow) and computing basic stats.
class RandomBytesGenerator extends WorkgroupMember {
  late Random _rand;

  @override
  Future setup() async {
    _rand = Random();
  }

  // Internal imnplementation, generating random bytes
  RandomBytes getBytes(int n) {
    var items = [Uint8List(n)];
    for (var i = 0; i < n; i++) {
      items[0][i] = _rand.nextInt(256);
    }

    var (min, max, avg) = getStats(items[0]);

    var t = TransferableTypedData.fromList(items);
    return RandomBytes(t, min, max, avg);
  }

  // And calculating stats
  (int min, int max, double avg) getStats(Uint8List items) {
    var min = 255;
    var max = 0;
    var avg = 0.0;

    for (var i = 0; i < items.length; i++) {
      if (items[i] < min) {
        min = items[i];
      }
      if (items[i] > max) {
        max = items[i];
      }
      avg += items[i];
    }

    avg /= items.length;

    return (min, max, avg);
  }

  // This method is called by the workgroup whenever there's
  // a call to `invoke()` on a proxy object in main isolate
  // `WorkerCommand` object is used to determine the operation requested (type of the object)
  // and transfer a payload - the WorkerCommand object is passed in from the main isolate as-is
  @override
  Future<dynamic> handle(WorkerCommand action) async {
    // Pre Dart 3.0
    // switch (action.runtimeType) {
    //   case GetNBytesAction:
    //     return getBytes((action as GetNBytesAction).numberOfBytes);
    //   case ComputeStats:
    //     var (min, max, avg) = getStats(
    //         (action as ComputeStats).bytes.materialize().asUint8List());

    // Using object patterns introduced in Dart 3.0
    switch (action) {
      case GetNBytesAction():
        return getBytes(action.numberOfBytes);
      case ComputeStats():
        var (min, max, avg) =
            getStats(action.bytes.materialize().asUint8List());

        return RandomBytes(TransferableTypedData.fromList([]), min, max, avg);
      default:
        throw 'Unknown action ${action.runtimeType}';
    }
  }
}

// WorkerCommand that requests N random bytes
class GetNBytesAction extends WorkerCommand {
  final int numberOfBytes;
  GetNBytesAction(this.numberOfBytes);
}

// A WorkerCommand that sends a list of bytes and receives statistics for that numbers
class ComputeStats extends WorkerCommand {
  // Using TransferableTypedData, a more verbose alternative to Uint8List (yet possibly faster)
  final TransferableTypedData bytes;
  ComputeStats(this.bytes);
}

// Payload that is used as return value for GetNBytes and
class RandomBytes {
  final TransferableTypedData bytes;
  final int min;
  final int max;
  final double avg;

  RandomBytes(this.bytes, this.min, this.max, this.avg);
}
