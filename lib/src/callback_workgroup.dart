import 'dart:async';
import 'dart:isolate';

import 'exceptions.dart';
import 'internal/messages.dart';

/// Used for creating jobs that can report progress back to the main isolate.
///
/// Derive from this class to create isolate jobs that need to communicate with
/// the main isolate during execution, for example to report progress.
abstract class CallbackWorkgroupJob<R, A> {
  /// Whether the job should be executed synchronously or asynchronously.
  final bool synchronous;

  /// Creates a new [CallbackWorkgroupJob].
  ///
  /// Set [synchronous] to true to use [executeSync] instead of [executeAsync].
  CallbackWorkgroupJob(this.synchronous);

  /// Asynchronous implementation of the job.
  /// Called when [synchronous] is false.
  Future<R> executeAsync();

  /// Synchronous implementation of the job.
  /// Called when [synchronous] is true.
  R executeSync();

  /// Sends data back to the callback in the main isolate.
  void report(A arg) {
    _sendPort?.send(IsolateCallbackArg<A>(arg));
  }

  SendPort? _sendPort;
  SendPort? _errorPort;
}

/// Manages execution of a [CallbackWorkgroupJob] in a dedicated isolate.
///
/// This class allows spawning a new isolate with a [CallbackWorkgroupJob]
/// without using an [IsolateWorkgroup].
class CallbackWorkgroup<R, A> {
  /// The job to execute in the isolate.
  final CallbackWorkgroupJob<R, A> job;

  /// Creates a new [CallbackWorkgroup] for the given [job].
  const CallbackWorkgroup(this.job);

  /// Executes the job in a new isolate.
  ///
  /// The [callback] will be called whenever the job sends data
  /// using [CallbackWorkgroupJob.report].
  ///
  /// If [onError] is provided, it will be called for any errors that occur
  /// during job execution. Otherwise, errors are propagated to the returned Future.
  Future<R> run(
    void Function(A arg)? callback, {
    Function(Object error, StackTrace stackTrace)? onError,
    bool errorsAreFatal = true,
    String? debugName,
    Duration? timeout,
    bool? combineStackTraces,
  }) async {
    combineStackTraces ??= true;

    final completer = Completer<R>();
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();

    job._sendPort = receivePort.sendPort;
    job._errorPort = errorPort.sendPort;

    Isolate? isolateInstance;
    Timer? timeoutTimer;

    try {
      isolateInstance = await Isolate.spawn<CallbackWorkgroupJob<R, A>>(
        _isolateBody,
        job,
        errorsAreFatal: errorsAreFatal,
        debugName: debugName,
        onError: errorPort.sendPort,
      );

      // Set timeout if requested
      if (timeout != null) {
        timeoutTimer = Timer(timeout, () {
          if (!completer.isCompleted) {
            final error = WorkgroupTimeoutException(
                'job execution',
                timeout.inMilliseconds,
                'Job execution timed out after ${timeout.inMilliseconds} ms',
                StackTrace.current);

            if (onError != null) {
              onError(error, StackTrace.current);
            } else {
              completer.completeError(error, StackTrace.current);
            }

            isolateInstance?.kill(priority: Isolate.immediate);
            receivePort.close();
            errorPort.close();
          }
        });
      }

      receivePort.listen((data) {
        if (data is IsolateCallbackArg<A>) {
          callback?.call(data.value);
        } else if (data is R) {
          if (!completer.isCompleted) {
            completer.complete(data);
            timeoutTimer?.cancel();
            isolateInstance?.kill();
            receivePort.close();
            errorPort.close();
          }
        } else if (data is _CallbackWorkgroupError) {
          if (!completer.isCompleted) {
            final error = data.error;
            final stackTrace = data.stackTrace;

            if (onError != null) {
              onError(error, stackTrace);
            } else {
              completer.completeError(error, stackTrace);
            }

            timeoutTimer?.cancel();
            isolateInstance?.kill();
            receivePort.close();
            errorPort.close();
          }
        }
      });

      errorPort.listen((e) {
        if (!completer.isCompleted) {
          if (e is _CallbackWorkgroupError) {
            final error = e.error;
            final stackTrace = e.stackTrace;

            // Capture current stack trace from where the error is caught in main isolate
            final callerStackTrace = StackTrace.current;
            final combinedStackTrace = combineStackTraces == true
                ? _combineStackTraces(stackTrace, callerStackTrace)
                : stackTrace;

            if (onError != null) {
              onError(error, combinedStackTrace);
            } else {
              completer.completeError(error, combinedStackTrace);
            }
          } else {
            if (onError != null) {
              onError(e, StackTrace.current);
            } else {
              completer.completeError(e);
            }
          }

          timeoutTimer?.cancel();
          isolateInstance?.kill();
          receivePort.close();
          errorPort.close();
        }
      });
    } catch (e, st) {
      if (!completer.isCompleted) {
        if (onError != null) {
          onError(e, st);
        } else {
          completer.completeError(e, st);
        }

        isolateInstance?.kill();
        receivePort.close();
        errorPort.close();
        timeoutTimer?.cancel();
      }
    }

    return completer.future;
  }
}

class _CallbackWorkgroupError {
  final Object error;
  final StackTrace stackTrace;

  _CallbackWorkgroupError(this.error, this.stackTrace);
}

void _isolateBody(CallbackWorkgroupJob job) async {
  try {
    final result =
        job.synchronous ? job.executeSync() : await job.executeAsync();
    job._sendPort!.send(result);
  } catch (e, st) {
    job._errorPort!.send(_CallbackWorkgroupError(e, st));
  }
}

// Helper method to combine stack traces
StackTrace _combineStackTraces(StackTrace isolateStack, StackTrace mainStack) {
  final isolateString = isolateStack.toString();
  final mainString = mainStack.toString();

  return StackTrace.fromString(
      '=== Stack trace in isolate (where error originated) ===\n'
      '$isolateString\n'
      '=== Stack trace in main isolate (where error was caught) ===\n'
      '$mainString');
}
