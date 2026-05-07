/// Tests for killing and removing specific isolates from the pool
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

// Simple test job for testing
class SimpleJob extends WorkgroupJob<int> {
  final int value;
  SimpleJob(this.value);

  @override
  Future<int> execute() async => value * 2;
}

// Long running job that can be used to test interruption
class LongRunningJob extends WorkgroupJob<String> {
  final int durationMs;
  final String result;
  LongRunningJob(this.durationMs, this.result);

  @override
  Future<String> execute() async {
    await Future.delayed(Duration(milliseconds: durationMs));
    return result;
  }
}

// Job that identifies which isolate it's running on
class IsolateIdentifyingJob extends WorkgroupJob<int> {
  @override
  Future<int> execute() async {
    // Return the hashCode of the current isolate to identify it
    return Isolate.current.hashCode;
  }
}

// Simple action class for testing
class GetStateAction extends WorkerCommand {}
class SetStateAction extends WorkerCommand {
  final String newState;
  SetStateAction(this.newState);
}

// Simple instance for testing
class TestInstance extends WorkgroupMember {
  String state = 'initial';

  @override
  Future<void> setup() async {
    state = 'initialized';
  }

  @override
  Future<void> dispose() async {
    state = 'disposed';
  }

  @override
  Future<dynamic> handle(WorkerCommand action) async {
    if (action is GetStateAction) {
      return state;
    } else if (action is SetStateAction) {
      state = action.newState;
      return null;
    }
    throw UnimplementedError('Unknown action: $action');
  }

  Future<String> getState() async => state;

  Future<void> setState(String newState) async {
    state = newState;
  }
}

void main() {
  group('IsolateWorkgroup.kill()', () {
    late IsolateWorkgroup pool;

    tearDown(() async {
      // Clean up after each test
      if (pool.state != WorkgroupState.disposed) {
        pool.shutdown();
      }
    });

    test('should kill a specific isolate and remove it from the pool', () async {
      pool = IsolateWorkgroup(4);
      await pool.launch();

      // Verify initial state
      expect(pool.isolatesCount, equals(4));
      expect(pool.state, equals(WorkgroupState.active));

      // Kill isolate at index 2
      pool.kill(2);

      // Verify isolate was removed
      expect(pool.isolatesCount, equals(4)); // Count remains the same for stable indices

      // Try to schedule a job specifically on the killed isolate - should fail
      expect(
        () => pool.dispatch(SimpleJob(10), 2),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('should fail pending jobs on the killed isolate', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();

      // Schedule a long-running job on isolate 1
      final jobFuture = pool.dispatch(LongRunningJob(5000, 'result'), 1);

      // Give it a moment to start
      await Future.delayed(Duration(milliseconds: 100));

      // Kill isolate 1
      pool.kill(1);

      // The job should fail with an exception
      expect(
        jobFuture,
        throwsA(isA<WorkgroupException>().having(
          (e) => e.message,
          'message',
          contains('Isolate #1 was killed'),
        )),
      );
    });

    test('should destroy all instances on the killed isolate', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();

      // Create instances on different isolates
      final instance1 = await pool.addInstance(TestInstance(), isolateIndex: 0);
      final instance2 = await pool.addInstance(TestInstance(), isolateIndex: 1);
      final instance3 = await pool.addInstance(TestInstance(), isolateIndex: 1);
      final instance4 = await pool.addInstance(TestInstance(), isolateIndex: 2);

      // Verify all instances are created
      expect(pool.memberCount, equals(4));

      // Kill isolate 1 (which has instance2 and instance3)
      pool.kill(1);

      // Verify only instances on isolate 1 were removed
      expect(pool.memberCount, equals(2));

      // Verify instance1 and instance4 are still in the pool
      expect(pool.pooledInstances.containsKey(instance1.memberId), isTrue);
      expect(pool.pooledInstances.containsKey(instance4.memberId), isTrue);

      // Verify instance2 and instance3 are removed
      expect(pool.pooledInstances.containsKey(instance2.memberId), isFalse);
      expect(pool.pooledInstances.containsKey(instance3.memberId), isFalse);
    });

    test('should allow other isolates to continue working normally', () async {
      pool = IsolateWorkgroup(4);
      await pool.launch();

      // Schedule jobs on different isolates
      final job0 = pool.dispatch(SimpleJob(5), 0);
      final job2 = pool.dispatch(SimpleJob(10), 2);
      final job3 = pool.dispatch(SimpleJob(15), 3);

      // Kill isolate 1
      pool.kill(1);

      // Jobs on other isolates should complete successfully
      expect(await job0, equals(10));
      expect(await job2, equals(20));
      expect(await job3, equals(30));

      // We should still be able to schedule new jobs on the remaining isolates
      final newJob0 = await pool.dispatch(SimpleJob(20), 0);
      final newJob2 = await pool.dispatch(SimpleJob(25), 2);
      final newJob3 = await pool.dispatch(SimpleJob(30), 3);

      expect(newJob0, equals(40));
      expect(newJob2, equals(50));
      expect(newJob3, equals(60));
    });

    test('should throw when trying to kill an invalid isolate index', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();

      // Try to kill isolate with negative index
      expect(
        () => pool.kill(-1),
        throwsA(isA<WorkgroupException>().having(
          (e) => e.message,
          'message',
          contains('Invalid isolate index'),
        )),
      );

      // Try to kill isolate with index >= isolatesCount
      expect(
        () => pool.kill(3),
        throwsA(isA<WorkgroupException>().having(
          (e) => e.message,
          'message',
          contains('Invalid isolate index'),
        )),
      );

      // Try to kill isolate with index way out of bounds
      expect(
        () => pool.kill(100),
        throwsA(isA<WorkgroupException>().having(
          (e) => e.message,
          'message',
          contains('Invalid isolate index'),
        )),
      );
    });

    test('should throw when trying to kill an already killed isolate', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();

      // Kill isolate 1
      pool.kill(1);

      // Try to kill it again
      expect(
        () => pool.kill(1),
        throwsA(isA<WorkgroupException>().having(
          (e) => e.message,
          'message',
          contains('does not exist or has already been removed'),
        )),
      );
    });

    test('should throw when pool is not started', () async {
      pool = IsolateWorkgroup(3);

      // Try to kill isolate before starting the pool
      expect(
        () => pool.kill(0),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('should throw when pool is stopped', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();
      pool.shutdown();

      // Try to kill isolate after stopping the pool
      expect(
        () => pool.kill(0),
        throwsA(isA<WorkgroupInactiveException>()),
      );
    });

    test('should handle multiple isolate kills correctly', () async {
      pool = IsolateWorkgroup(5);
      await pool.launch();

      // Create instances on different isolates
      final instance0 = await pool.addInstance(TestInstance(), isolateIndex: 0);
      final instance1 = await pool.addInstance(TestInstance(), isolateIndex: 1);
      final instance2 = await pool.addInstance(TestInstance(), isolateIndex: 2);
      final instance3 = await pool.addInstance(TestInstance(), isolateIndex: 3);
      final instance4 = await pool.addInstance(TestInstance(), isolateIndex: 4);

      expect(pool.memberCount, equals(5));

      // Kill isolates 1 and 3
      pool.kill(1);
      pool.kill(3);

      expect(pool.memberCount, equals(3));

      // Verify correct instances remain
      expect(pool.pooledInstances.containsKey(instance0.memberId), isTrue);
      expect(pool.pooledInstances.containsKey(instance1.memberId), isFalse);
      expect(pool.pooledInstances.containsKey(instance2.memberId), isTrue);
      expect(pool.pooledInstances.containsKey(instance3.memberId), isFalse);
      expect(pool.pooledInstances.containsKey(instance4.memberId), isTrue);

      // Remaining isolates should still work
      final job0 = await pool.dispatch(SimpleJob(10), 0);
      final job2 = await pool.dispatch(SimpleJob(20), 2);
      final job4 = await pool.dispatch(SimpleJob(30), 4);

      expect(job0, equals(20));
      expect(job2, equals(40));
      expect(job4, equals(60));
    });

    test('should clean up all resources properly when killing an isolate', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();

      // Create an instance on isolate 1
      final instance = await pool.addInstance(TestInstance(), isolateIndex: 1);

      // Schedule a job on isolate 1
      final jobFuture = pool.dispatch(LongRunningJob(5000, 'test'), 1);

      // Give it a moment to start
      await Future.delayed(Duration(milliseconds: 100));

      // Kill isolate 1
      pool.kill(1);

      // Verify job fails
      expect(
        jobFuture,
        throwsA(isA<WorkgroupException>()),
      );

      // Verify instance is removed
      expect(pool.pooledInstances.containsKey(instance.memberId), isFalse);

      // Note: Port cleanup verification would need access to internal state
      // which is not directly exposed. The implementation does clean them up.
    });

    test('should maintain correct isolate indices after killing', () async {
      pool = IsolateWorkgroup(4);
      await pool.launch();

      // Get isolate identities before killing
      final id0 = await pool.dispatch(IsolateIdentifyingJob(), 0);
      final id2 = await pool.dispatch(IsolateIdentifyingJob(), 2);
      final id3 = await pool.dispatch(IsolateIdentifyingJob(), 3);

      // Kill isolate 1
      pool.kill(1);

      // Verify the same isolates are still at their indices
      final newId0 = await pool.dispatch(IsolateIdentifyingJob(), 0);
      final newId2 = await pool.dispatch(IsolateIdentifyingJob(), 2);
      final newId3 = await pool.dispatch(IsolateIdentifyingJob(), 3);

      expect(newId0, equals(id0));
      expect(newId2, equals(id2));
      expect(newId3, equals(id3));
    });

    test('should handle rapid sequential kills', () async {
      pool = IsolateWorkgroup(5);
      await pool.launch();

      // Kill multiple isolates in rapid succession
      pool.kill(0);
      pool.kill(2);
      pool.kill(4);

      // Remaining isolates 1 and 3 should still work
      final job1 = await pool.dispatch(SimpleJob(100), 1);
      final job3 = await pool.dispatch(SimpleJob(200), 3);

      expect(job1, equals(200));
      expect(job3, equals(400));

      // Verify killed isolates can't be used
      expect(() => pool.dispatch(SimpleJob(10), 0), throwsA(isA<WorkgroupException>()));
      expect(() => pool.dispatch(SimpleJob(10), 2), throwsA(isA<WorkgroupException>()));
      expect(() => pool.dispatch(SimpleJob(10), 4), throwsA(isA<WorkgroupException>()));
    });

    test('should properly handle instance creation failure on killed isolate', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();

      // Kill isolate 1
      pool.kill(1);

      // Try to create an instance on the killed isolate
      expect(
        () => pool.addInstance(TestInstance(), isolateIndex: 1),
        throwsA(isA<WorkgroupException>()),
      );

      // Creating instances on other isolates should still work
      final instance0 = await pool.addInstance(TestInstance(), isolateIndex: 0);
      final instance2 = await pool.addInstance(TestInstance(), isolateIndex: 2);

      expect(pool.pooledInstances.containsKey(instance0.memberId), isTrue);
      expect(pool.pooledInstances.containsKey(instance2.memberId), isTrue);
    });

    test('should handle pending instance creations when killing isolate', () async {
      pool = IsolateWorkgroup(3);
      await pool.launch();

      // Start creating multiple instances on isolate 1 with delays
      final creationFutures = <Future<MemberProxy>>[];
      for (int i = 0; i < 3; i++) {
        creationFutures.add(
          Future.delayed(Duration(milliseconds: 50 * i))
              .then((_) => pool.addInstance(TestInstance(), isolateIndex: 1))
        );
      }

      // Kill isolate 1 before all creations complete
      await Future.delayed(Duration(milliseconds: 75));
      pool.kill(1);

      // Some creations might succeed, others should fail
      // Count how many succeed vs fail
      int succeeded = 0;
      int failed = 0;

      for (final future in creationFutures) {
        try {
          await future;
          succeeded++;
        } catch (e) {
          if (e is WorkgroupException) {
            failed++;
          } else {
            rethrow;
          }
        }
      }

      // At least one should have failed (those that were pending when kill happened)
      expect(failed, greaterThan(0));

      // Verify total attempts equals succeeded + failed
      expect(succeeded + failed, equals(3));

      // Verify no instances remain on the killed isolate
      for (final entry in pool.pooledInstances.values) {
        expect(entry.isolateIndex, isNot(equals(1)));
      }
    });

    test('should track alive isolate count correctly', () async {
      pool = IsolateWorkgroup(5);
      await pool.launch();

      // Initial state - all isolates alive
      expect(pool.isolatesCount, equals(5));
      expect(pool.liveIsolateCount, equals(5));

      // Kill one isolate
      pool.kill(2);
      expect(pool.isolatesCount, equals(5)); // isolatesCount stays same
      expect(pool.liveIsolateCount, equals(4)); // liveIsolateCount decreases

      // Kill two more isolates
      pool.kill(0);
      pool.kill(4);
      expect(pool.isolatesCount, equals(5)); // isolatesCount still same
      expect(pool.liveIsolateCount, equals(2)); // Only 1 and 3 remain

      // Add a new isolate
      await pool.addIsolate();
      expect(pool.isolatesCount, equals(6)); // isolatesCount increases
      expect(pool.liveIsolateCount, equals(3)); // liveIsolateCount increases

      // Kill another and add another
      pool.kill(1);
      expect(pool.liveIsolateCount, equals(2)); // 3 and 5 remain

      await pool.addIsolate();
      expect(pool.isolatesCount, equals(7));
      expect(pool.liveIsolateCount, equals(3)); // 3, 5, and 6 remain

      // Verify remaining isolates work correctly
      final job3 = await pool.dispatch(SimpleJob(10), 3);
      final job5 = await pool.dispatch(SimpleJob(20), 5);
      final job6 = await pool.dispatch(SimpleJob(30), 6);

      expect(job3, equals(20));
      expect(job5, equals(40));
      expect(job6, equals(60));
    });
  });
}
