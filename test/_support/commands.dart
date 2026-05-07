/// WorkerCommand fixtures shared across the test suite.
///
/// These commands cover the breadth of behaviors the suite needs to exercise:
/// echo, arithmetic, throwing, sleeping, counter mutation, host notification,
/// and an "escape" command that schedules a microtask throw to bypass the
/// package's try/catch (see spec §5).
@TestOn('vm')
library;

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

class EchoCommand<T> extends WorkerCommand {
  EchoCommand(this.value);
  final T value;
}

class AddCommand extends WorkerCommand {
  AddCommand(this.a, this.b);
  final int a;
  final int b;
}

class ThrowCommand extends WorkerCommand {
  ThrowCommand(this.message);
  final String message;
}

class SleepCommand extends WorkerCommand {
  SleepCommand(this.durationMs);
  final int durationMs;
}

class IncrementCounter extends WorkerCommand {
  IncrementCounter([this.by = 1]);
  final int by;
}

class GetCounter extends WorkerCommand {}

class NotifyHostCommand extends WorkerCommand {
  NotifyHostCommand(this.payload);
  final Object? payload;
}

/// Schedules a microtask that throws — bypassing the worker's try/catch
/// (spec §5: errors thrown from a Timer/microtask escape package handling
/// and reach the builtin onError port as `[String, String]`).
class ScheduleTimerThrow extends WorkerCommand {
  ScheduleTimerThrow(this.message);
  final String message;
}
