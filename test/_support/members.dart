/// WorkgroupMember fixtures shared across the test suite.
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import 'commands.dart';

/// Echoes payloads, returns sums, and rethrows on demand.
class EchoMember extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    if (command is EchoCommand) return command.value;
    if (command is AddCommand) return command.a + command.b;
    if (command is ThrowCommand) throw Exception(command.message);
    if (command is SleepCommand) {
      await Future<void>.delayed(Duration(milliseconds: command.durationMs));
      return command.durationMs;
    }
    throw UnimplementedError('EchoMember: unhandled ${command.runtimeType}');
  }
}

/// Holds an in-memory counter; useful for state-persistence checks.
class CounterMember extends WorkgroupMember {
  int _count = 0;

  @override
  Future<void> setup() async {
    _count = 0;
  }

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    if (command is IncrementCounter) {
      _count += command.by;
      return _count;
    }
    if (command is GetCounter) return _count;
    throw UnimplementedError('CounterMember: unhandled ${command.runtimeType}');
  }
}

/// Calls back into the host via [notifyHost] when [NotifyHostCommand] arrives.
class NotifyingMember extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    if (command is NotifyHostCommand) {
      return notifyHost<Object?>(command);
    }
    if (command is EchoCommand) return command.value;
    throw UnimplementedError(
      'NotifyingMember: unhandled ${command.runtimeType}',
    );
  }
}

/// Throws inside [setup] — useful for testing setup-failure propagation.
class FailingSetupMember extends WorkgroupMember {
  FailingSetupMember(this.message);
  final String message;

  @override
  Future<void> setup() async {
    throw Exception(message);
  }

  @override
  Future<dynamic> handle(WorkerCommand command) async => null;
}

/// Holds a non-sendable [StreamController] field — must be rejected by
/// [WorkgroupMemberValidation.validateForIsolate].
///
/// Note: the validation heuristic in `canBeSentToIsolate` matches against
/// the member's `toString()` / `runtimeType.toString()`, so the class name
/// itself must contain a trigger word ("Stream", "Completer", etc.) for
/// the heuristic to fire. The class name below is intentional.
class StreamHoldingNonSendableMember extends WorkgroupMember {
  // ignore: close_sinks
  final StreamController<int> controller = StreamController<int>();

  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async => null;
}

/// Setup deliberately delays for [delayMs] ms — useful for timing and
/// initialization-policy assertions.
class SlowSetupMember extends WorkgroupMember {
  SlowSetupMember(this.delayMs);
  final int delayMs;

  @override
  Future<void> setup() async {
    await Future<void>.delayed(Duration(milliseconds: delayMs));
  }

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    if (command is EchoCommand) return command.value;
    return null;
  }
}

/// Reports its dispose state by calling [notifyHost] from inside [dispose].
/// Tests use this to confirm that destroyInstance triggers dispose.
class DisposeTrackerMember extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    if (command is EchoCommand) return command.value;
    return null;
  }

  @override
  Future<void> dispose() async {
    // Fire-and-forget host notification; the proxy's remoteCallback in the
    // test sets a flag.
    try {
      await notifyHost<Object?>(NotifyHostCommand('disposed'));
    } catch (_) {
      // Ignore — host may already have torn down the proxy.
    }
  }
}

/// On any handle() call, schedules a microtask that throws the next event
/// loop turn. The throw escapes the package's try/catch (spec §5).
class TimerEscapingMember extends WorkgroupMember {
  TimerEscapingMember(this.message);
  final String message;

  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand command) async {
    if (command is ScheduleTimerThrow) {
      // Use Timer.zero so the throw happens after handle() returns,
      // bypassing the worker body's try/catch.
      Timer(Duration.zero, () {
        throw command.message;
      });
      return 'scheduled';
    }
    if (command is EchoCommand) return command.value;
    return null;
  }
}
