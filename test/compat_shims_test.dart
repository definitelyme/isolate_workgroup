/// Lock-in tests for the public compat shims documented in
/// possible-test-cases.txt §3 and spec §3 (Decisions Captured).
///
/// These shims forward to canonical names. They are NOT marked
/// `@Deprecated` for now — the suite keeps them as supported public API.
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/commands.dart';

class _ShimMember extends WorkgroupMember {
  bool setupCalled = false;

  @override
  Future<void> setup() async {
    setupCalled = true;
  }

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    if (command is EchoCommand) return 'echo:${command.value}';
    return null;
  }
}

void main() {
  group('WorkgroupMember.init()', () {
    test('forwards to setup()', () async {
      final m = _ShimMember();
      expect(m.setupCalled, isFalse);
      await m.init();
      expect(m.setupCalled, isTrue);
    });
  });

  group('WorkgroupMember.receiveRemoteCall()', () {
    test('returns the same value as handle()', () async {
      final m = _ShimMember();
      await m.setup();
      final viaHandle = await m.handle(EchoCommand<int>(7));
      final viaShim = await m.receiveRemoteCall(EchoCommand<int>(7));
      expect(viaShim, viaHandle);
      expect(viaShim, 'echo:7');
    });
  });

  group('MemberProxy.callRemoteMethod()', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(2);
      wg.setErrorHandler(IsolateErrorType.all, (_) {});
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test('returns the same as invoke()', () async {
      final proxy = await wg.addInstance(_ShimMember());
      final viaInvoke = await proxy.invoke<String>(EchoCommand<int>(11));
      final viaShim =
          await proxy.callRemoteMethod<String>(EchoCommand<int>(11));
      expect(viaShim, viaInvoke);
      expect(viaShim, 'echo:11');
    });

    test(
      'callRemoteMethod with `isolate:` cross-isolate variant routes through '
      'the same path as invoke(isolate:)',
      () async {
        // Mirrors dexter app's calling convention: route a member's call to
        // a different isolate by passing `isolate:`.
        final proxy = await wg.addInstance(_ShimMember(), isolateIndex: 0);
        // Call with isolate: 1 — instance doesn't exist there, so the
        // routing attempt fails. The point of this test is that the shim
        // forwards the parameter — both call sites must produce the same
        // failure shape.
        Object? invokeError;
        try {
          await proxy.invoke<String>(EchoCommand<int>(1), isolate: 1);
        } catch (e) {
          invokeError = e;
        }
        Object? shimError;
        try {
          await proxy.callRemoteMethod<String>(EchoCommand<int>(1), isolate: 1);
        } catch (e) {
          shimError = e;
        }
        expect(invokeError, isNotNull);
        expect(shimError, isNotNull);
        expect(shimError.runtimeType, invokeError.runtimeType);
      },
    );
  });

  group('MemberProxy id getters', () {
    late IsolateWorkgroup wg;

    setUp(() async {
      wg = IsolateWorkgroup(3);
      await wg.launch();
    });

    tearDown(() => wg.shutdown());

    test('instanceId == memberId', () async {
      final proxy = await wg.addInstance(_ShimMember());
      expect(proxy.instanceId, proxy.memberId);
    });

    test('isolateId == workerIndex', () async {
      final p2 = await wg.addInstance(_ShimMember(), isolateIndex: 2);
      expect(p2.isolateId, p2.workerIndex);
      expect(p2.isolateId, 2);
    });
  });
}
