/// Subprocess target for spec §7.15: addInstance + invoke + destroyInstance
/// + shutdown.
import 'package:isolate_workgroup/isolate_workgroup.dart';

class _Cmd extends WorkerCommand {}

class _Member extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async => 42;
}

Future<void> main() async {
  final wg = IsolateWorkgroup(2);
  await wg.launch();
  final p = await wg.addInstance(_Member());
  final r = await p.invoke<int>(_Cmd());
  if (r != 42) {
    throw StateError('expected 42, got $r');
  }
  wg.destroyInstance(p);
  wg.shutdown();
}
