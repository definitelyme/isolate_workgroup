import 'dart:async';

import 'enums.dart';
import 'health_config.dart';

/// All initialization options for [IsolateWorkgroup].
///
/// Pass an instance to the [IsolateWorkgroup] constructor. [IsolateWorkgroup.launch]
/// takes no arguments — everything lives here.
class WorkgroupConfig {
  /// Optional function run once inside each worker isolate at startup.
  ///
  /// Must be a top-level or static function — closures will throw because they
  /// cannot cross the isolate boundary via [SendPort].
  final FutureOr<void> Function()? onSetup;

  /// Whether uncaught errors in worker isolates terminate the main isolate.
  ///
  /// Defaults to `false`.
  final bool fatalErrors;

  /// Generates a debug label for isolate [index].
  ///
  /// Defaults to `'pooled_isolate_N'` when null.
  final String Function(int index)? labelBuilder;

  /// Whether isolates start one-at-a-time or all concurrently.
  ///
  /// Defaults to [InitializationPolicy.concurrent].
  final InitializationPolicy startupPolicy;

  /// Health-check configuration for all isolates in the workgroup.
  ///
  /// Defaults to [WorkgroupHealthConfig] with sensible defaults.
  final WorkgroupHealthConfig health;

  const WorkgroupConfig({
    this.onSetup,
    this.fatalErrors = false,
    this.labelBuilder,
    this.startupPolicy = InitializationPolicy.concurrent,
    this.health = const WorkgroupHealthConfig(),
  });
}
