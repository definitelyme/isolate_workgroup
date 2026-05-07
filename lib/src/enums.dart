/// Defines the initialization behavior of isolates in the workgroup.
enum InitializationPolicy {
  /// Isolates start one at a time to avoid resource contention.
  sequential,

  /// All isolates start in parallel (faster but may contend).
  concurrent;
}

/// Represents the current state of an [IsolateWorkgroup].
enum WorkgroupState {
  /// Workgroup created but not yet launched. Call [IsolateWorkgroup.launch].
  idle,

  /// Workgroup is running and ready to accept jobs and members.
  active,

  /// Workgroup has been shut down. Create a new instance to restart.
  disposed
}

/// Categorization of error types that can occur in worker isolates.
///
/// Used with [IsolateWorkgroup.setErrorHandler] to register targeted handlers.
enum IsolateErrorType {
  /// Catch-all handler for all error types.
  all,

  /// Errors during isolate initialization.
  initialization,

  /// Errors related to job execution.
  job,

  /// Errors related to pooled member operations.
  instance,

  /// Errors related to inter-isolate communication.
  communication,

  /// Errors that don't fit any other category.
  unknown
}
