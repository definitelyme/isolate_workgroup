/// A Dart library for managing a dynamic group of worker isolates.
///
/// Supports one-off job dispatch, persistent members with state, health
/// monitoring, and runtime workgroup resizing (add / kill individual isolates).
///
/// # Quick start
///
/// ```dart
/// import 'package:isolate_workgroup/isolate_workgroup.dart';
///
/// final wg = IsolateWorkgroup(4);
/// await wg.launch();
///
/// // One-off job
/// final result = await wg.dispatch(MyJob());
///
/// // Persistent member
/// final proxy = await wg.addInstance(MyMember());
/// final value  = await proxy.invoke(MyCommand());
/// wg.destroyInstance(proxy);
///
/// wg.shutdown();
/// ```
library;

export 'src/callback_workgroup.dart';
export 'src/enums.dart';
export 'src/exceptions.dart';
export 'src/health_config.dart';
export 'src/workgroup.dart';
export 'src/workgroup_config.dart';
export 'src/workgroup_member.dart';
export 'src/workgroup_job.dart';
export 'src/workgroup_validation.dart';
