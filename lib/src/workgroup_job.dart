import 'dart:async';
import 'internal/external_job.dart';

/// A one-off operation submitted to an [IsolateWorkgroup] for execution.
///
/// Subclass this to define work that runs in a worker isolate and returns a
/// result of type [E]. Fields on the subclass are transmitted to the isolate,
/// so they must be sendable (see [SendPort.send]).
abstract class WorkgroupJob<E> {
  const WorkgroupJob();

  /// Performs the work in the worker isolate.
  Future<E> execute();

  // For internal dispatch only.
  // ignore: library_private_types_in_public_api
  ExternalJob<E> wrap() => ExternalJob(this);
}
