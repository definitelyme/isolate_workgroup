/// Workgroup member functionality tests
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

// Test instance A with simple operations
class InstanceA extends WorkgroupMember {
  int sum(int x, int y) {
    return x + y;
  }

  Future wait(int durationMs) async {
    await Future.delayed(Duration(milliseconds: durationMs));
  }

  Future<String> concat(String arg1, String arg2) {
    return Future(() => arg1 + arg2);
  }

  void deffered(int value, Function callback) {
    Future.delayed(Duration(milliseconds: 10), () {
      callback(value + 1);
    });
  }

  void fail() {
    throw 'Action failed';
  }

  @override
  Future<void> setup() async {
    // Simple initialization
  }

  @override
  Future handle(WorkerCommand action) async {
    switch (action) {
      case SumIntAction _:
        var ac = action;
        return sum(ac.x, ac.y);
      case ConcatAction _:
        var ac = action;
        return concat(ac.x, ac.y);
      case CallbackIssuingAction _:
        var ac = action;
        return deffered(ac.x, (y) async {
          var x = await notifyHost<int>(CallbackAction(y));
          await notifyHost(CallbackAction(x + 1));
        });
      case FailAction _:
        return fail();
      default:
        throw 'Unknown action';
    }
  }
}

// Test instance B with different operations
class InstanceB extends WorkgroupMember {
  double sum(double x, double y) {
    return x + y;
  }

  @override
  Future<void> setup() async {
    // Simple initialization
  }

  @override
  Future handle(WorkerCommand action) async {
    switch (action) {
      case SumIntAction _:
        var ac = action;
        return ac.x + ac.y;
      case SumDynamicAction _:
        var ac = action;
        if (ac.x is int && ac.y is int) return (ac.x + ac.y) as int;
        if (ac.x is double && ac.y is double) return sum(ac.x, ac.y);
        throw 'SumDynamic supports only int and double';
      default:
        throw 'Unknown action recevied';
    }
  }
}

// Test worker that can fail on start
class WorkerWithInit extends WorkgroupMember {
  final bool failOnStart;

  WorkerWithInit({this.failOnStart = false});

  @override
  Future<void> setup() async {
    if (failOnStart) throw 'Failed on start';
    await Future.delayed(Duration(milliseconds: 10));
  }

  @override
  Future handle(WorkerCommand action) async {
    if (action is GetNameAction) {
      return 'Worker';
    }
    return null;
  }
}

// Value holder for state testing
class ValueHolder extends WorkgroupMember {
  String initialValue;
  ValueHolder(this.initialValue);

  late List<String> _values;

  @override
  Future<void> setup() async {
    _values = [initialValue];
  }

  @override
  Future<dynamic> handle(WorkerCommand action) async {
    switch (action) {
      case GetValues _:
        return _values;
      case SetValue _:
        var v = action.value;
        _values.add(v);
        return;
      default:
        throw 'Unknown action ${action.runtimeType}';
    }
  }
}

// Actions for testing
class SumIntAction extends WorkerCommand {
  final int x;
  final int y;
  SumIntAction(this.x, this.y);
}

class SumDynamicAction extends WorkerCommand {
  final dynamic x;
  final dynamic y;
  SumDynamicAction(this.x, this.y);
}

class ConcatAction extends WorkerCommand {
  final String x;
  final String y;
  ConcatAction(this.x, this.y);
}

class CallbackIssuingAction extends WorkerCommand {
  final int x;
  CallbackIssuingAction(this.x);
}

class CallbackAction extends WorkerCommand {
  final int x;
  CallbackAction(this.x);
}

class FailAction extends WorkerCommand {}

class GetNameAction extends WorkerCommand {}

class GetValues extends WorkerCommand {}

class SetValue extends WorkerCommand {
  final String value;
  SetValue(this.value);
}

class UnknownAction extends WorkerCommand {}

void main() {
  group('Instance Creation and Lifecycle', () {
    late IsolateWorkgroup pool;

    setUp(() async {
      pool = IsolateWorkgroup(4);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();
    });

    tearDown(() {
      pool.shutdown();
    });

    test('Creating single pooled instance', () async {
      await pool.addInstance(InstanceA());
      expect(pool.memberCount, 1);
    });

    test('Creating multiple pooled instances', () async {
      for (var i = 0; i < 20; i++) {
        await pool.addInstance(InstanceA());
      }
      expect(pool.memberCount, 20);
    });

    test('Creating different type pooled instances', () async {
      for (var i = 0; i < 20; i++) {
        await pool.addInstance(i % 2 == 0 ? InstanceA() : InstanceB());
      }
      expect(pool.memberCount, 20);
    });

    test('Instances are created in different isolates', () async {
      var instances = <MemberProxy>[];
      for (var i = 0; i < 20; i++) {
        var pi = await pool.addInstance(i % 2 == 0 ? InstanceA() : InstanceB());
        instances.add(pi);
      }
      expect(pool.memberCount, 20);

      var pools = List<int>.filled(4, 0);
      for (var pi in instances) {
        pools[pool.indexOfInstance(pi)]++;
      }

      for (var p in pools) {
        expect(p, 5);
      }
    });

    test('Instance with initialization failure', () async {
      var errorMessage = '';
      try {
        await pool.addInstance(WorkerWithInit(failOnStart: true));
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('Failed on start'));
    });

    test('Instance on specific isolate', () async {
      final instance = await pool.addInstance(InstanceA(), isolateIndex: 0);
      expect(instance.isolateId, 0);

      final instance2 = await pool.addInstance(InstanceA(), isolateIndex: 1);
      expect(instance2.isolateId, 1);
    });

    test('Instance with invalid isolate index', () async {
      await expectLater(
        pool.addInstance(InstanceA(), isolateIndex: 10),
        throwsA(isA<WorkgroupException>()),
      );
    });
  });

  group('Instance Destruction', () {
    late IsolateWorkgroup pool;

    setUp(() async {
      pool = IsolateWorkgroup(4);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();
    });

    tearDown(() {
      pool.shutdown();
    });

    test('Destroy pooled instance', () async {
      var instances = <MemberProxy>[];
      for (var i = 0; i < 5; i++) {
        var pi = await pool.addInstance(InstanceA());
        instances.add(pi);
      }
      expect(pool.memberCount, 5);

      pool.destroyInstance(instances[0]);
      expect(pool.memberCount, 4);
    });

    test('Destroy already destroyed instance', () async {
      var instance = await pool.addInstance(InstanceA());

      pool.destroyInstance(instance);
      expect(pool.memberCount, 0);

      // Destroying an already destroyed instance should not throw
      pool.destroyInstance(instance);
      expect(pool.memberCount, 0);
    });

    test('Destroy instance from specific isolate', () async {
      final instance = await pool.addInstance(InstanceA(), isolateIndex: 1);

      pool.destroyInstance(instance, isolate: 1);
      expect(pool.memberCount, 0);
    });

    test('Destroy instance with wrong isolate index throws', () async {
      final instance = await pool.addInstance(InstanceA(), isolateIndex: 0);

      expect(
        () => pool.destroyInstance(instance, isolate: 2),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('Pooled instance can be destroyed', () async {
      var pi = ValueHolder('Hello');
      var px = await pool.addInstance(pi);
      var r = await px.invoke<List<String>>(GetValues());

      expect(r[0], 'Hello');

      pool.destroyInstance(px);

      expect(() => px.invoke(GetValues()), throwsA(isA<WorkgroupMemberNotFoundException>()));
    });
  });

  group('Remote Method Calls', () {
    late IsolateWorkgroup pool;
    late MemberProxy instanceA;
    late MemberProxy instanceB;

    setUp(() async {
      pool = IsolateWorkgroup(4);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();
      instanceA = await pool.addInstance(InstanceA());
      instanceB = await pool.addInstance(InstanceB());
    });

    tearDown(() {
      pool.shutdown();
    });

    test('Simple action returns result', () async {
      var res = await instanceA.invoke(SumIntAction(2, 2));
      expect(res, 4);
    });

    test('Async action returns result', () async {
      var res = await instanceA.invoke(ConcatAction('Hello ', 'world'));
      expect(res, 'Hello world');
    });

    test('Failed action returns error', () async {
      var errorMessage = '';
      try {
        await instanceA.invoke(FailAction());
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('Action failed'));
    });

    test('Unknown action throws error', () async {
      var errorMessage = '';
      try {
        await instanceB.invoke(ConcatAction('', ''));
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('Unknown action recevied'));
    });

    test('Dynamic type handling', () async {
      var intResult = await instanceB.invoke<int>(SumDynamicAction(1, 2));
      expect(intResult, 3);

      var doubleResult = await instanceB.invoke<double>(SumDynamicAction(10.5, 10.5));
      expect(doubleResult, 21.0);
    });

    test('Invalid dynamic types throw error', () async {
      var errorMessage = '';
      try {
        await instanceB.invoke<int>(SumDynamicAction('', ''));
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('SumDynamic supports only int and double'));
    });

    test('Multiple concurrent requests to same instance', () async {
      var futures = <Future>[];
      for (int i = 0; i < 50; i++) {
        futures.add(instanceA.invoke(SumIntAction(i, i)));
      }

      var results = await Future.wait(futures);
      for (int i = 0; i < 50; i++) {
        expect(results[i], i * 2);
      }
    });

    test('Sending second request before first completes', () async {
      var f1 = instanceA.invoke(CallbackIssuingAction(1));
      var f2 = instanceA.invoke(SumIntAction(1, 1));

      await f1;
      var x2 = await f2;
      expect(x2, 2);
    });
  });

  group('State Management', () {
    late IsolateWorkgroup pool;

    setUp(() async {
      pool = IsolateWorkgroup(2);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();
    });

    tearDown(() {
      pool.shutdown();
    });

    test('Pooled instance maintains state', () async {
      var pi = ValueHolder('Hello');
      var px = await pool.addInstance(pi);
      var r = await px.invoke<List<String>>(GetValues());

      expect(r[0], 'Hello');

      await px.invoke(SetValue('world'));
      r = await px.invoke<List<String>>(GetValues());

      expect(r[0], 'Hello');
      expect(r[1], 'world');
    });

    test('Multiple instances have independent state', () async {
      var instance1 = await pool.addInstance(ValueHolder('First'));
      var instance2 = await pool.addInstance(ValueHolder('Second'));

      await instance1.invoke(SetValue('Value1'));
      await instance2.invoke(SetValue('Value2'));

      var result1 = await instance1.invoke<List<String>>(GetValues());
      var result2 = await instance2.invoke<List<String>>(GetValues());

      expect(result1, ['First', 'Value1']);
      expect(result2, ['Second', 'Value2']);
    });

    test('Pooled instance throws on unknown action', () async {
      var pi = ValueHolder('Hello');
      var px = await pool.addInstance(pi);
      var r = await px.invoke<List<String>>(GetValues());

      expect(r[0], 'Hello');

      expect(
        px.invoke(UnknownAction()),
        throwsA(
          isA<WorkgroupIsolateError>().having(
            (e) => e.toString(),
            'error message',
            contains('Unknown action UnknownAction'),
          ),
        ),
      );
    });
  });

  group('Instance Callbacks', () {
    late IsolateWorkgroup pool;

    setUp(() async {
      pool = IsolateWorkgroup(4);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();
    });

    tearDown(() {
      pool.shutdown();
    });

    test('Instance with callback receives calls', () async {
      var completer = Completer<int>();
      var callCount = 0;

      var instance = await pool.addInstance(InstanceA(), callback: (a) {
        if (a is CallbackAction) {
          callCount++;
          if (callCount == 1) {
            completer.complete(a.x);
          }
          return a.x + 1;
        }
        return null;
      });

      await instance.invoke(CallbackIssuingAction(1));

      var res = await completer.future;
      expect(res, 2);

      // Wait for second callback
      await Future.delayed(Duration(milliseconds: 50));
      expect(callCount, 2);
    });

    test('Instance without callback handles gracefully', () async {
      var instance = await pool.addInstance(InstanceA());

      // Should not throw when callback is called but not set
      await instance.invoke(CallbackIssuingAction(1));

      // Wait a bit to ensure no errors
      await Future.delayed(Duration(milliseconds: 50));

      // Should still be able to make normal calls
      var result = await instance.invoke(SumIntAction(5, 5));
      expect(result, 10);
    });
  });

  group('Instance Health and Pool State', () {
    test('Calling method with pool stopped throws', () async {
      var pool = IsolateWorkgroup(4);
      await pool.launch();

      var instance = await pool.addInstance(InstanceA());
      expect(pool.memberCount, 1);

      pool.shutdown();

      expect(
        () => instance.invoke(SumIntAction(1, 1)),
        throwsA(isA<WorkgroupInactiveException>()),
      );
    });

    test('Stopping pool with pending instance creation', () async {
      var pool = IsolateWorkgroup(5);
      await pool.launch();

      late Future f;
      var errorMessage = '';

      try {
        for (var i = 0; i < 25; i++) {
          f = pool.addInstance(InstanceA());
          if (i < 24) await f;
        }

        pool.shutdown();
        await f;
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('cancelling instance creation requests'));
    });

    test('Stopping pool with pending requests', () async {
      var pool = IsolateWorkgroup(5);
      await pool.launch();

      late Future f;
      late MemberProxy pi;
      var errorMessage = '';

      try {
        for (var i = 0; i < 25; i++) {
          pi = await pool.addInstance(InstanceA());
        }

        expect(pool.memberCount, 25);

        for (var i = 0; i < 25; i++) {
          f = pi.invoke<int>(SumIntAction(i, 1));
          if (i < 24) await f;
        }

        pool.shutdown();
        await f;
      } catch (e) {
        errorMessage = e.toString();
      }

      expect(errorMessage, contains('cancelling pending request'));
    });

    test('Instance cleanup on pool stop', () async {
      final pool = IsolateWorkgroup(3);
      await pool.launch();

      // Create multiple instances
      final instances = <MemberProxy>[];
      for (int i = 0; i < 6; i++) {
        instances.add(await pool.addInstance(InstanceA()));
      }

      expect(pool.memberCount, 6);

      // Stop pool
      pool.shutdown();

      // All operations should fail after stop
      for (final instance in instances) {
        expect(
          () => instance.invoke(SumIntAction(1, 1)),
          throwsA(isA<WorkgroupInactiveException>()),
        );
      }
    });
  });

  group('Instance Load Distribution', () {
    test('Instances distributed evenly across isolates', () async {
      final pool = IsolateWorkgroup(4);
      await pool.launch();

      final instanceCounts = List<int>.filled(4, 0);

      // Create 40 instances
      for (int i = 0; i < 40; i++) {
        final instance = await pool.addInstance(InstanceA());
        instanceCounts[pool.indexOfInstance(instance)]++;
      }

      // Each isolate should have roughly the same number of instances
      for (var count in instanceCounts) {
        expect(count, 10);
      }

      pool.shutdown();
    });

    test('Load balancing with mixed instance types', () async {
      final pool = IsolateWorkgroup(3);
      await pool.launch();

      final instances = <MemberProxy>[];

      // Create different types of instances
      for (int i = 0; i < 30; i++) {
        if (i % 3 == 0) {
          instances.add(await pool.addInstance(InstanceA()));
        } else if (i % 3 == 1) {
          instances.add(await pool.addInstance(InstanceB()));
        } else {
          instances.add(await pool.addInstance(WorkerWithInit()));
        }
      }

      expect(pool.memberCount, 30);

      // Verify all instances are functional
      for (int i = 0; i < instances.length; i++) {
        if (i % 3 == 0) {
          final result = await instances[i].invoke(SumIntAction(i, i));
          expect(result, i * 2);
        } else if (i % 3 == 1) {
          final result = await instances[i].invoke(SumIntAction(i, 1));
          expect(result, i + 1);
        } else {
          final result = await instances[i].invoke(GetNameAction());
          expect(result, 'Worker');
        }
      }

      pool.shutdown();
    });
  });

  group('Request Tracking', () {
    late IsolateWorkgroup pool;

    setUp(() async {
      pool = IsolateWorkgroup(4);

      // Suppress error logs for cleaner test output
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();
    });

    tearDown(() {
      pool.shutdown();
    });

    test('Request count grows and declines', () async {
      final instance = await pool.addInstance(InstanceA());

      var r1 = instance.invoke(ConcatAction('Hello ', 'world'));
      expect(pool.pendingCount, 1);

      var r2 = instance.invoke(ConcatAction('Hello ', 'world'));
      expect(pool.pendingCount, 2);

      await Future.wait([r1, r2]);
      expect(pool.pendingCount, 0);
    });

    test('Request tracking across multiple instances', () async {
      final instances = <MemberProxy>[];
      for (int i = 0; i < 4; i++) {
        instances.add(await pool.addInstance(InstanceA()));
      }

      // Start multiple requests
      final futures = <Future>[];
      for (var instance in instances) {
        futures.add(instance.invoke(ConcatAction('test', 'ing')));
      }

      // Should have pending requests
      expect(pool.pendingCount, greaterThan(0));

      await Future.wait(futures);

      // All requests should be complete
      expect(pool.pendingCount, 0);
    });
  });
}
