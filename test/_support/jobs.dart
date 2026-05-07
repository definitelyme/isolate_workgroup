/// WorkgroupJob fixtures shared across the test suite.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

class EchoJob<T> extends WorkgroupJob<T> {
  EchoJob(this.value);
  final T value;

  @override
  Future<T> execute() async => value;
}

class AddJob extends WorkgroupJob<int> {
  AddJob(this.a, this.b);
  final int a;
  final int b;

  @override
  Future<int> execute() async => a + b;
}

class ThrowJob extends WorkgroupJob<int> {
  ThrowJob(this.message);
  final String message;

  @override
  Future<int> execute() async {
    throw Exception(message);
  }
}

class SleepJob extends WorkgroupJob<String> {
  SleepJob(this.durationMs, this.tag);
  final int durationMs;
  final String tag;

  @override
  Future<String> execute() async {
    await Future<void>.delayed(Duration(milliseconds: durationMs));
    return tag;
  }
}

/// Burns CPU computing the n-th Fibonacci number iteratively.
/// Used to compare parallel vs serial throughput.
class CpuBoundJob extends WorkgroupJob<int> {
  CpuBoundJob(this.iterations);
  final int iterations;

  @override
  Future<int> execute() async {
    var a = 0;
    var b = 1;
    for (var i = 2; i <= iterations; i++) {
      final tmp = a + b;
      a = b;
      b = tmp;
    }
    return b;
  }
}

/// Sends a TransferableTypedData round-trip — exercises that path through
/// canBeSentToIsolate and the worker body.
class TransferableJob extends WorkgroupJob<int> {
  TransferableJob(this.data);
  final TransferableTypedData data;

  @override
  Future<int> execute() async {
    final view = data.materialize().asUint8List();
    var sum = 0;
    for (final b in view) {
      sum += b;
    }
    return sum;
  }
}

/// Mirrors the real-world `Job<P,R>` shape used by the dexter app: a single
/// parametric job class that runs an arbitrary static handler against a
/// sendable parameter.
class ParamsJob<P, R> extends WorkgroupJob<R> {
  ParamsJob(this.param, this.handler);
  final P param;
  final R Function(P) handler;

  @override
  Future<R> execute() async => handler(param);
}

/// Job that returns null — verifies null result handling.
class NullJob extends WorkgroupJob<int?> {
  @override
  Future<int?> execute() async => null;
}

/// Job that returns void — verifies the void/no-result path through
/// dispatch's generic `T` parameter.
class VoidJob extends WorkgroupJob<void> {
  @override
  Future<void> execute() async {
    // No-op.
  }
}
