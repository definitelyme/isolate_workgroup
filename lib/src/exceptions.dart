/// Base exception for all isolate workgroup errors.
class WorkgroupException implements Exception {
  final String message;
  final StackTrace? stackTrace;

  const WorkgroupException(this.message, [this.stackTrace]);

  @override
  String toString() {
    if (stackTrace != null && stackTrace != StackTrace.empty) {
      return '$message\n$stackTrace';
    }
    return message;
  }
}

/// Thrown when referencing a member that does not exist.
class WorkgroupMemberNotFoundException extends WorkgroupException {
  const WorkgroupMemberNotFoundException(super.message, [super.stackTrace]);
}

/// Thrown when attempting to use a workgroup that has been shut down.
class WorkgroupInactiveException extends WorkgroupException {
  const WorkgroupInactiveException(super.message, [super.stackTrace]);
}

/// Thrown when in-flight jobs are cancelled because the workgroup was shut down.
class WorkgroupJobAbortedException extends WorkgroupException {
  const WorkgroupJobAbortedException(super.message, [super.stackTrace]);
}

/// Thrown when sending to a member that has not finished initializing.
class WorkgroupNotReadyException extends WorkgroupException {
  const WorkgroupNotReadyException(super.message, [super.stackTrace]);
}

/// Thrown when an isolate sends back an unexpected message shape.
class InvalidWorkgroupResponseException extends WorkgroupException {
  const InvalidWorkgroupResponseException(super.message, [super.stackTrace]);
}

/// Wraps an error that originated inside a worker isolate.
class WorkgroupIsolateError extends WorkgroupException {
  final Object originalError;
  final int isolateIndex;
  final StackTrace originalStackTrace;

  const WorkgroupIsolateError(
    this.originalError,
    this.isolateIndex,
    String message, [
    this.originalStackTrace = StackTrace.empty,
  ]) : super(message, originalStackTrace);

  @override
  String toString() {
    if (originalStackTrace != StackTrace.empty) {
      return 'Error in isolate #$isolateIndex: $message\n$originalStackTrace';
    }
    return 'Error in isolate #$isolateIndex: $message';
  }

  Object get unwrappedError => originalError;

  WorkgroupIsolateError withCombinedStackTrace(StackTrace mainStackTrace) {
    final combined = _combineStackTraces(originalStackTrace, mainStackTrace);
    return WorkgroupIsolateError(originalError, isolateIndex, message, combined);
  }

  static StackTrace _combineStackTraces(StackTrace original, StackTrace main) {
    return StackTrace.fromString(
      '=== Stack trace in isolate (where error originated) ===\n'
      '$original\n'
      '=== Stack trace in main isolate (where error was caught) ===\n'
      '$main',
    );
  }
}

/// Thrown when a worker isolate fails to complete its setup phase.
class WorkgroupSetupException extends WorkgroupException {
  final int isolateIndex;

  const WorkgroupSetupException(
    this.isolateIndex,
    super.message, [
    super.stackTrace,
  ]);

  @override
  String toString() {
    if (stackTrace != null && stackTrace != StackTrace.empty) {
      return 'Failed to initialize isolate #$isolateIndex: $message\n$stackTrace';
    }
    return 'Failed to initialize isolate #$isolateIndex: $message';
  }
}

/// Thrown when an isolate operation exceeds its time budget.
class WorkgroupTimeoutException extends WorkgroupException {
  final String operation;
  final int timeoutMs;

  const WorkgroupTimeoutException(
    this.operation,
    this.timeoutMs,
    super.message, [
    super.stackTrace,
  ]);

  @override
  String toString() {
    if (stackTrace != null && stackTrace != StackTrace.empty) {
      return '$operation timed out after $timeoutMs ms: $message\n$stackTrace';
    }
    return '$operation timed out after $timeoutMs ms: $message';
  }
}

/// Thrown when a worker isolate fails health checks and is unresponsive.
class WorkgroupMemberDeadException extends WorkgroupException {
  final int isolateIndex;

  const WorkgroupMemberDeadException(
    this.isolateIndex,
    super.message, [
    super.stackTrace,
  ]);

  @override
  String toString() {
    if (stackTrace != null && stackTrace != StackTrace.empty) {
      return 'Isolate #$isolateIndex is dead or unresponsive: $message\n$stackTrace';
    }
    return 'Isolate #$isolateIndex is dead or unresponsive: $message';
  }
}
