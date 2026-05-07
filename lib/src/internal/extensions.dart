import 'dart:async';
import 'dart:isolate';

import '../enums.dart';
import '../exceptions.dart';
import '../workgroup.dart';
import '../workgroup_member.dart';
import 'messages.dart';

extension IsolateWorkgroupExtensions on IsolateWorkgroup {
  /// Sends a request to a member in the workgroup.
  ///
  /// This method sends a command to a specific member and returns a future
  /// that completes with the result.
  ///
  /// Parameters:
  /// - [instanceId]: The ID of the member to send the request to
  /// - [action]: The command to send to the member
  /// - [isolateIndex]: Optional index of the worker to execute the command on.
  ///   If specified, this overrides the worker where the member was created.
  ///   If not specified or negative, the member's original worker is used.
  ///
  /// Throws exceptions if:
  /// - The member does not exist
  /// - The member is not yet started
  /// - The workgroup has been shut down
  /// - The specified worker index is invalid
  Future<R> sendRequest<R>(int instanceId, WorkerCommand action, [int? isolateIndex]) async {
    isolateIndex ??= -1;

    if (state == WorkgroupState.disposed) {
      throw WorkgroupInactiveException('Workgroup has been shut down, cannot send request');
    }

    if (!members.containsKey(instanceId)) {
      throw WorkgroupMemberNotFoundException('Cannot send request to non-existing member, memberId $instanceId');
    }

    final instance = members[instanceId]!;

    if (instance.state == WorkgroupMemberStatus.starting) {
      throw WorkgroupNotReadyException('Cannot send request to instance in Starting state, instanceId $instanceId');
    }

    // Use the specified isolate index if provided, otherwise use the instance's original isolate
    final targetIsolate = (isolateIndex >= 0) ? isolateIndex : instance.isolateIndex;

    // Validate the isolate index
    if (targetIsolate > mainToWorkerSendPorts.length - 1) {
      throw WorkgroupException(
        "Invalid isolate index $targetIsolate (only ${mainToWorkerSendPorts.length} isolates available). Valid indices are 0...${mainToWorkerSendPorts.length - 1}",
      );
    }

    // Warning: Cross-isolate call detection
    if (isolateIndex >= 0 && isolateIndex != instance.isolateIndex) {
      print('⚠️ Warning: Attempting to call instance $instanceId on isolate $targetIsolate, '
          'but instance was created in isolate ${instance.isolateIndex}. '
          'This may fail if the instance does not exist in the target isolate.');
    }

    if (healthConfig.enabled && healthConfig.checkBeforeDispatching) {
      final isHealthy = await ensureIsolateHealthyInternal(targetIsolate);
      if (!isHealthy) {
        throw WorkgroupMemberDeadException(
          targetIsolate,
          'Isolate #$targetIsolate hosting instance $instanceId is not responsive',
        );
      }
    }

    final request = Request(instanceId, action);

    mainToWorkerSendPorts[targetIsolate]!.send(request);

    final completer = Completer<R>();
    requestCompleters[request.id] = completer;

    // Track which instance this request belongs to (for proper cleanup on isolate death)
    trackRequestToInstanceInternal(request.id, instanceId);

    return completer.future;
  }
}

abstract class InternalWorkgroupMember {
  late SendPort _sendPort;

  /// The [SendPort] of the isolate where this instance is executed.
  // ignore: unnecessary_getters_setters
  SendPort get sendPort => _sendPort;

  /// @nodoc
  ///
  /// Internal method to set the send port.
  /// This method is only intended for internal use by the isolate_workgroup package.
  ///
  /// WARNING: Do not call this method from your application code.
  set sendPort(SendPort port) => _sendPort = port;
}

extension DynamicX on dynamic {
  R let<R>(R Function(dynamic it) func) {
    if (this != null) return func(this);
    return this as R;
  }

  R also<R>(R Function(dynamic it) func) {
    return func(this);
  }
}

extension FunctionObjX<T> on T {
  R let<R>(R Function(T it) func) {
    if (this != null) return func(this);
    return this as R;
  }

  R also<R>(R Function(T it) func) {
    return func(this);
  }
}
