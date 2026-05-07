/// Validation tests for [canBeSentToIsolate] and the
/// [WorkgroupMemberValidation] extension.
///
/// Spec §7.8 — exactly one test per branch, plus closure-capture
/// pitfalls and the tightened 'NEVER sendable' message.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:developer' show UserTag;
import 'dart:ffi' show DynamicLibrary;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

// Members for validation extension tests.
class _ValidMember extends WorkgroupMember {
  final int n;
  final String s;
  _ValidMember(this.n, this.s);

  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async => null;
}

class _CompleterHoldingMember extends WorkgroupMember {
  final Completer<int> completer = Completer<int>();

  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async => null;
}

class _StreamHoldingMember extends WorkgroupMember {
  // ignore: close_sinks
  final StreamController<int> controller = StreamController<int>();

  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async => null;
}

void main() {
  group('canBeSentToIsolate — sendable primitives', () {
    test('null', () => expect(canBeSentToIsolate(null), isTrue));
    test('int', () => expect(canBeSentToIsolate(42), isTrue));
    test('double', () => expect(canBeSentToIsolate(3.14), isTrue));
    test('num', () {
      // num is the supertype; an int IS a num. Sendable via the int branch.
      final num n = 7;
      expect(canBeSentToIsolate(n), isTrue);
    });
    test('String', () => expect(canBeSentToIsolate('hello'), isTrue));
    test('bool', () => expect(canBeSentToIsolate(true), isTrue));
    test('SendPort', () {
      final rp = ReceivePort();
      expect(canBeSentToIsolate(rp.sendPort), isTrue);
      rp.close();
    });
    test('TransferableTypedData', () {
      final ttd = TransferableTypedData.fromList([Uint8List(8)]);
      expect(canBeSentToIsolate(ttd), isTrue);
    });
    test('Capability', () {
      expect(canBeSentToIsolate(Capability()), isTrue);
    });
    test('Type', () {
      expect(canBeSentToIsolate(int), isTrue);
    });
  });

  group('canBeSentToIsolate — non-sendable types', () {
    test('ReceivePort', () {
      final rp = ReceivePort();
      expect(canBeSentToIsolate(rp), isFalse);
      rp.close();
    });
    test('RawReceivePort', () {
      final rp = RawReceivePort();
      expect(canBeSentToIsolate(rp), isFalse);
      rp.close();
    });
    test('DynamicLibrary (process)', () {
      // dart:ffi DynamicLibrary.process() exists in VM.
      try {
        final lib = DynamicLibrary.process();
        expect(canBeSentToIsolate(lib), isFalse);
      } on UnsupportedError {
        // Some platforms / configs reject this; skip rather than fail.
      }
    });
    test('UserTag', () {
      final tag = UserTag('isolate_workgroup_test_tag');
      expect(canBeSentToIsolate(tag), isFalse);
    });
    test('Stream', () {
      // ignore: close_sinks
      final controller = StreamController<int>();
      expect(canBeSentToIsolate(controller.stream), isFalse);
      controller.close();
    });
    test('StreamController', () {
      // ignore: close_sinks
      final controller = StreamController<int>();
      expect(canBeSentToIsolate(controller), isFalse);
      controller.close();
    });
    test('StreamSubscription', () {
      // ignore: close_sinks
      final controller = StreamController<int>();
      final sub = controller.stream.listen((_) {});
      expect(canBeSentToIsolate(sub), isFalse);
      sub.cancel();
      controller.close();
    });
    test('Completer', () {
      expect(canBeSentToIsolate(Completer<int>()), isFalse);
    });
    test('IsolateWorkgroup', () {
      final wg = IsolateWorkgroup(1);
      expect(canBeSentToIsolate(wg), isFalse);
    });
    test('MemberProxy', () async {
      final wg = IsolateWorkgroup(1);
      await wg.launch();
      final p = await wg.addInstance(_ValidMember(1, 'a'));
      expect(canBeSentToIsolate(p), isFalse);
      wg.shutdown();
    });
  });

  group('canBeSentToIsolate — collections', () {
    test('List of sendables is sendable', () {
      expect(canBeSentToIsolate(<int>[1, 2, 3]), isTrue);
    });
    test('List with a non-sendable element is not sendable', () {
      // ignore: close_sinks
      final controller = StreamController<int>();
      expect(canBeSentToIsolate([1, controller, 3]), isFalse);
      controller.close();
    });
    test('Map of sendables is sendable', () {
      expect(canBeSentToIsolate({'a': 1, 'b': 2}), isTrue);
    });
    test('Map with a non-sendable value is not sendable', () {
      // ignore: close_sinks
      final controller = StreamController<int>();
      expect(canBeSentToIsolate({'k': controller}), isFalse);
      controller.close();
    });
    test('Set of sendables is sendable', () {
      expect(canBeSentToIsolate({'x', 'y', 'z'}), isTrue);
    });
    test('Set with a non-sendable element is not sendable', () {
      // ignore: close_sinks
      final controller = StreamController<int>();
      expect(canBeSentToIsolate({1, controller}), isFalse);
      controller.close();
    });
    test('Nested collection (List of Maps) of sendables is sendable', () {
      expect(
        canBeSentToIsolate([
          {'a': 1, 'b': 2},
          {'c': [3, 4]},
        ]),
        isTrue,
      );
    });
    test(
      'Nested collection with a buried non-sendable is not sendable',
      () {
        // ignore: close_sinks
        final controller = StreamController<int>();
        expect(
          canBeSentToIsolate([
            {'a': 1},
            {'b': [controller]},
          ]),
          isFalse,
        );
        controller.close();
      },
    );
  });

  group('WorkgroupMemberValidation extension', () {
    test('valid member produces empty error list', () {
      final errors = _ValidMember(1, 'a').validateForIsolate();
      expect(errors, isEmpty);
    });

    test(
      'member with Completer field produces canonical error '
      "with the tightened 'NEVER sendable' wording",
      () {
        final errors = _CompleterHoldingMember().validateForIsolate();
        expect(errors, isNotEmpty);
        expect(errors.first, contains('non-sendable objects'));
        expect(errors.first, contains('NEVER sendable'));
        expect(errors.first, contains('Completer'));
      },
    );

    test(
      'member with StreamController field produces canonical error',
      () {
        final errors = _StreamHoldingMember().validateForIsolate();
        expect(errors, isNotEmpty);
        expect(errors.first, contains('NEVER sendable'));
      },
    );

    test('error message lists key non-sendable categories', () {
      final errors = _CompleterHoldingMember().validateForIsolate();
      final msg = errors.first;
      // Spot-check a few categories from the canonical message.
      expect(msg, contains('ReceivePort'));
      expect(msg, contains('Stream'));
      expect(msg, contains('StreamController'));
      expect(msg, contains('Completer'));
      expect(msg, contains('IsolateWorkgroup'));
    });
  });
}
