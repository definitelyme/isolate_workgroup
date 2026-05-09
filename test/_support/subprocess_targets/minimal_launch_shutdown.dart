// Minimal subprocess target for spec §7.15: `launch()` then `shutdown()`,
// nothing else. Used to triage whether the documented `~25 s` shutdown
// hang lives in `IsolateWorkgroup.shutdown` itself or in the example.

import 'package:isolate_workgroup/isolate_workgroup.dart';

Future<void> main() async {
  final wg = IsolateWorkgroup(2);
  await wg.launch();
  wg.shutdown();
}
