import 'dart:async';
import 'dart:isolate';

import 'enums.dart';
import 'exceptions.dart';
import 'internal/export.dart';
import 'workgroup.dart';

/// Base class for commands sent between the main isolate and worker members.
///
/// Subclass to define the set of commands your [WorkgroupMember] understands.
abstract class WorkerCommand {}

/// Callback type for actions initiated by the worker and handled in the main isolate.
typedef MemberCallback<T> = T Function(WorkerCommand command);

/// A persistent object that lives inside a worker isolate managed by [IsolateWorkgroup].
///
/// Subclass this to define state and logic that should run in a worker isolate.
/// The subclass is serialized and sent to the isolate on [IsolateWorkgroup.addInstance];
/// only sendable fields (see [SendPort.send]) are transferred.
abstract class WorkgroupMember extends InternalWorkgroupMember {
  WorkgroupMember() : memberId = instanceIdCounter++;

  /// Unique ID for this member instance.
  final int memberId;

  // Kept for internal dispatch compatibility.
  int get instanceId => memberId;

  /// Sends a [WorkerCommand] to the main isolate and awaits the result.
  ///
  /// Used by subclasses to call back into the main isolate during processing.
  Future<R> notifyHost<R>(WorkerCommand command) async {
    return _sendRequest<R>(command);
  }

  /// Called once when this member is created inside its worker isolate.
  ///
  /// Initialize any resources, open files, create caches, etc. here.
  Future<void> setup();

  /// Called when this member is removed from the workgroup.
  ///
  /// Override to release resources. Default implementation does nothing.
  Future<void> dispose() async {}

  /// Receives a [WorkerCommand] from the main isolate and returns a result.
  ///
  /// Typically implemented as a switch on the command type.
  Future<dynamic> handle(WorkerCommand command);

  // Internal compatibility shims so the worker body can call the old names.
  Future<void> init() => setup();
  Future<dynamic> receiveRemoteCall(WorkerCommand command) => handle(command);

  Future<R> _sendRequest<R>(WorkerCommand command) {
    final request = Request(memberId, command);
    sendPort.send(request);
    final completer = Completer<R>();
    isolateRequestCompleters[request.id] = completer;
    return completer.future;
  }
}

/// Proxy for a [WorkgroupMember] held in the main isolate.
///
/// Returned from [IsolateWorkgroup.addInstance]. Use [invoke] to send commands
/// to the remote member and await their results.
class MemberProxy<T> {
  const MemberProxy({
    required this.memberId,
    required this.workerIndex,
    required IsolateWorkgroup pool,
    required this.remoteCallback,
    SendPort? sendPort,
  })  : _pool = pool,
        _sendPort = sendPort;

  /// Unique ID that matches the [WorkgroupMember.memberId] in the worker isolate.
  final int memberId;

  // Kept for internal compatibility.
  int get instanceId => memberId;

  /// Zero-based index of the isolate where this member is running.
  final int workerIndex;

  // Kept for internal compatibility.
  int get isolateId => workerIndex;

  /// Called in the main isolate when the worker member calls [WorkgroupMember.notifyHost].
  ///
  /// Null means the member cannot initiate calls back to the main isolate.
  final MemberCallback<T>? remoteCallback;

  final SendPort? _sendPort;
  final IsolateWorkgroup _pool;

  SendPort? get sendPort => _sendPort;

  /// Sends [command] to the remote [WorkgroupMember] and returns the result.
  ///
  /// Throws [WorkgroupInactiveException] if the workgroup has been shut down.
  /// Re-throws any exception thrown inside the worker with a combined stack trace.
  Future<R> invoke<R>(WorkerCommand command, {int? isolate}) {
    isolate ??= -1;

    if (_pool.state == WorkgroupState.disposed) {
      throw WorkgroupInactiveException(
        'Workgroup has been shut down, cannot invoke member method',
      );
    }

    final targetIsolateIndex = isolate >= 0 ? isolate : workerIndex;
    return _pool.sendRequest<R>(memberId, command, targetIsolateIndex);
  }

  // Internal compatibility shim so existing internal code compiles unchanged.
  Future<R> callRemoteMethod<R>(WorkerCommand action, {int? isolate}) =>
      invoke<R>(action, isolate: isolate);
}
