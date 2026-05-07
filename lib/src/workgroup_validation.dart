import 'dart:async';
import 'dart:developer' show UserTag;
import 'dart:ffi' show DynamicLibrary;
import 'dart:isolate';

import 'workgroup.dart';
import 'workgroup_member.dart';

/// Returns true if [object] can be sent across an isolate boundary.
bool canBeSentToIsolate(dynamic object) {
  if (object == null ||
      object is num ||
      object is int ||
      object is double ||
      object is String ||
      object is bool ||
      object is SendPort ||
      object is TransferableTypedData ||
      object is Capability ||
      object is Type) {
    return true;
  }

  if (object is ReceivePort ||
      object is DynamicLibrary ||
      object is UserTag ||
      object is RawReceivePort ||
      object is Stream ||
      object is StreamController ||
      object is StreamSubscription ||
      object is Completer ||
      object.runtimeType.toString().contains('Completer') ||
      object.runtimeType.toString().contains('Finalizable') ||
      object.runtimeType.toString().contains('Finalizer') ||
      object.runtimeType.toString().contains('NativeFinalizer') ||
      object is IsolateWorkgroup ||
      object is MemberProxy) {
    return false;
  }

  if (object is List) return object.every(canBeSentToIsolate);
  if (object is Map) {
    return object.entries
        .every((e) => canBeSentToIsolate(e.key) && canBeSentToIsolate(e.value));
  }
  if (object is Set) return object.every(canBeSentToIsolate);

  if (object is WorkgroupMember) {
    final s = object.toString() + object.runtimeType.toString();
    if (s.contains('MemberProxy') ||
        s.contains('IsolateWorkgroup') ||
        s.contains('Completer') ||
        s.contains('Stream') ||
        s.contains('Socket') ||
        s.contains('NativeFieldWrapperClass1')) {
      return false;
    }
  }

  return true;
}

extension WorkgroupMemberValidation on WorkgroupMember {
  /// Returns validation errors for this member, or an empty list if sendable.
  List<String> validateForIsolate() {
    final errors = <String>[];

    if (!canBeSentToIsolate(this)) {
      errors.add('Member contains non-sendable objects.\n'
          'Only the following types can be sent:\n'
          '- null, bool, int, double, String\n'
          '- List, Map, or Set (with sendable elements)\n'
          '- TransferableTypedData\n'
          '- SendPort\n'
          '- Capability\n'
          '- Type\n\n'
          'NEVER sendable:\n'
          '- Objects with native resources (Socket, etc.)\n'
          '- ReceivePort, RawReceivePort\n'
          '- DynamicLibrary\n'
          '- Finalizable, Finalizer, NativeFinalizer\n'
          '- UserTag\n'
          '- Stream, StreamController, StreamSubscription\n'
          '- Completer\n'
          '- MemberProxy\n'
          '- IsolateWorkgroup\n\n'
          'See: https://api.flutter.dev/flutter/dart-isolate/SendPort/send.html');
    }

    return errors;
  }
}
