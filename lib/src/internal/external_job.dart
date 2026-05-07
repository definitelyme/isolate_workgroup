import '../workgroup_job.dart';

/// Wraps a [WorkgroupJob] for direct dispatch to the worker body, bypassing the queue.
class ExternalJob<T> {
  final WorkgroupJob<T> job;

  const ExternalJob(this.job);
}
