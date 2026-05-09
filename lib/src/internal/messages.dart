import 'dart:async';
import 'dart:isolate';

import '../enums.dart';
import '../workgroup_member.dart';
import '../workgroup_job.dart';
import 'export.dart';

/// Message to request an action on a workgroup member
class Request {
  Request(this.instanceId, this.action) : id = requestIdCounter++;

  final WorkerCommand action;
  final int id;
  final int instanceId;

  @override
  String toString() {
    return 'Request(instanceId: $instanceId, action: $action, id: $id)';
  }
}

/// Message with the response from a request
class Response {
  const Response(this.requestId, this.result, this.error,
      [this.stackTrace, this.isolateIndex = -1]);

  final dynamic error;
  final int isolateIndex;
  final int requestId;
  final dynamic result;
  final StackTrace? stackTrace;

  @override
  String toString() {
    return 'Response(requestId: $requestId, result: $result, error: $error, stackTrace: $stackTrace, isolateIndex: $isolateIndex)';
  }
}

/// Message with the response from a creation request
class CreationResponse {
  const CreationResponse(this.instanceId, this.error, [this.stackTrace]);

  final dynamic error;
  final int instanceId;
  final StackTrace? stackTrace;

  @override
  String toString() {
    return 'CreationResponse(instanceId: $instanceId, error: $error, stackTrace: $stackTrace)';
  }
}

/// Message to request destruction of a workgroup member
class DestroyRequest {
  const DestroyRequest(this.instanceId);

  final int instanceId;

  @override
  String toString() {
    return 'DestroyRequest(instanceId: $instanceId)';
  }
}

/// Instance status
enum WorkgroupMemberStatus { starting, started }

/// Entry in the workgroup's member map.
class MemberEntry<T> {
  MemberEntry(this.instance, this.isolateIndex);

  final MemberProxy<T> instance;
  final int isolateIndex;

  WorkgroupMemberStatus state = WorkgroupMemberStatus.starting;

  @override
  String toString() {
    return 'MemberEntry(instance: $instance, isolateIndex: $isolateIndex, state: $state)';
  }
}

/// Parameters for worker isolate initialization
class WorkerLaunchParams {
  const WorkerLaunchParams(
    this.sendPort,
    this.errorSendPort,
    this.isolateIndex,
    this.stopwatch, {
    this.initFunc,
    this.nextIsolateIndex,
    this.policy,
    this.initializationError,
    required this.debugName,
  });

  final FutureOr<void> Function()? initFunc;
  final SendPort? errorSendPort;
  final dynamic initializationError;
  final int isolateIndex;
  final int? nextIsolateIndex;
  final InitializationPolicy? policy;
  final SendPort sendPort;
  final Stopwatch stopwatch;
  final String debugName;

  @override
  String toString() {
    return 'WorkerLaunchParams(sendPort: $sendPort, errorSendPort: $errorSendPort, isolateIndex: $isolateIndex, initFunc: $initFunc, nextIsolateIndex: $nextIsolateIndex, policy: $policy, initializationError: $initializationError)';
  }

  WorkerLaunchParams copyWith({
    SendPort? sendPort,
    SendPort? errorSendPort,
    int? isolateIndex,
    FutureOr<void> Function()? initFunc,
    Stopwatch? stopwatch,
    int? nextIsolateIndex,
    InitializationPolicy? policy,
    dynamic initializationError,
    String? debugName,
  }) {
    return WorkerLaunchParams(
      sendPort ?? this.sendPort,
      errorSendPort ?? this.errorSendPort,
      isolateIndex ?? this.isolateIndex,
      stopwatch ?? this.stopwatch,
      initFunc: initFunc ?? this.initFunc,
      nextIsolateIndex: nextIsolateIndex ?? this.nextIsolateIndex,
      policy: policy ?? this.policy,
      initializationError: initializationError ?? this.initializationError,
      debugName: debugName ?? this.debugName,
    );
  }
}

/// Internal representation of a job
class WorkgroupJobRequest<T> {
  const WorkgroupJobRequest(this.job, this.jobIndex, this.isolateIndex,
      {this.started = false});

  final int isolateIndex;
  final WorkgroupJob<T> job;
  final int jobIndex;
  final bool started;

  @override
  String toString() {
    return 'WorkgroupJobRequest(job: $job, jobIndex: $jobIndex, isolateIndex: $isolateIndex, started: $started)';
  }

  WorkgroupJobRequest<T> copyWith({
    int? isolateIndex,
    bool? started,
  }) {
    return WorkgroupJobRequest(
      job,
      jobIndex,
      isolateIndex ?? this.isolateIndex,
      started: started ?? this.started,
    );
  }
}

/// Result of a job execution
class WorkgroupJobResult {
  const WorkgroupJobResult(
    this.data,
    this.jobIndex,
    this.isolateIndex,
    this.error,
    this.stackTrace,
  );

  final dynamic data;
  final dynamic error;
  final int isolateIndex;
  final int jobIndex;
  final StackTrace? stackTrace;

  @override
  String toString() {
    return 'WorkgroupJobResult(data: $data, jobIndex: $jobIndex, isolateIndex: $isolateIndex, error: $error, stackTrace: $stackTrace)';
  }
}

/// Callback argument wrapper
class IsolateCallbackArg<A> {
  const IsolateCallbackArg(this.value);

  final A value;
}
