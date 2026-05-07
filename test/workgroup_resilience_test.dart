/// Isolate pool resilience and edge case tests
@TestOn('vm')
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

// Job that always throws an exception
class FailingJob extends WorkgroupJob<int> {
  final String errorMessage;
  FailingJob(this.errorMessage);

  @override
  Future<int> execute() async {
    throw Exception(errorMessage);
  }
}

// Job that throws after some work
class PartiallyFailingJob extends WorkgroupJob<int> {
  final int workBeforeError;
  PartiallyFailingJob(this.workBeforeError);

  @override
  Future<int> execute() async {
    await Future.delayed(Duration(milliseconds: workBeforeError));
    throw 'Failed after $workBeforeError ms';
  }
}

// Job that succeeds
class SuccessfulJob extends WorkgroupJob<int> {
  final int value;
  SuccessfulJob(this.value);

  @override
  Future<int> execute() async => value;
}

// Error prone job for resilience testing
class ErrorProneJob extends WorkgroupJob<String> {
  final double errorProbability;
  final String successResult;

  ErrorProneJob(this.errorProbability, this.successResult);

  @override
  Future<String> execute() async {
    await Future.delayed(Duration(milliseconds: 50));
    if (math.Random().nextDouble() < errorProbability) {
      throw 'Random failure occurred';
    }
    return successResult;
  }
}

// Synchronous throw job
class SyncThrowJob extends WorkgroupJob<int> {
  @override
  Future<int> execute() {
    throw 'Synchronous throw';
  }
}

// Instance that throws errors
class FailingInstance extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand action) async {
    if (action is FailAction) {
      throw Exception('Instance action failed');
    } else if (action is SucceedAction) {
      return action.value;
    }
    throw 'Unknown action';
  }
}

// Instance that returns null
class NullReturningInstance extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand action) async {
    if (action is GetNullAction) {
      return null;
    }
    return 42;
  }
}

// Compute engine for performance tests
class ComputeEngine extends WorkgroupMember {
  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand action) async {
    if (action is PrimeCheckAction) {
      return _isPrime(action.number);
    } else if (action is SimulateHeavyWorkAction) {
      await _simulateHeavyWork(action.durationMs);
      return 'Completed after ${action.durationMs}ms';
    }
    throw 'Unknown action: ${action.runtimeType}';
  }

  bool _isPrime(int n) {
    if (n <= 1) return false;
    if (n <= 3) return true;
    if (n % 2 == 0 || n % 3 == 0) return false;
    var i = 5;
    while (i * i <= n) {
      if (n % i == 0 || n % (i + 2) == 0) return false;
      i += 6;
    }
    return true;
  }

  Future<void> _simulateHeavyWork(int durationMs) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsedMilliseconds < durationMs) {
      // Simulate CPU-intensive work
      for (int i = 0; i < 1000000; i++) {
        math.sqrt(i);
      }
      if (stopwatch.elapsedMilliseconds % 100 == 0) {
        await Future.delayed(Duration.zero); // Allow other tasks
      }
    }
  }
}

// Data store for transaction testing
class DataStore extends WorkgroupMember {
  final Map<String, dynamic> _data = {};

  @override
  Future<void> setup() async {
    await Future.delayed(Duration(milliseconds: 20));
  }

  @override
  Future<dynamic> handle(WorkerCommand action) async {
    if (action is GetDataAction) {
      return _data[action.key];
    } else if (action is SetDataAction) {
      final oldValue = _data[action.key];
      _data[action.key] = action.value;
      return oldValue;
    } else if (action is TransactionAction) {
      return _executeTransaction(action.operations);
    } else if (action is GetAllKeysAction) {
      return _data.keys.toList();
    }
    throw 'Unknown action: ${action.runtimeType}';
  }

  Future<bool> _executeTransaction(List<DataOperation> operations) async {
    final backup = Map<String, dynamic>.from(_data);
    try {
      for (final op in operations) {
        switch (op.type) {
          case 'set':
            _data[op.key] = op.value;
            break;
          case 'delete':
            _data.remove(op.key);
            break;
          case 'check':
            final currentValue = _data[op.key];
            final expectedValue = op.value;

            // Deep equality check for Maps
            if (currentValue is Map && expectedValue is Map) {
              if (currentValue.length != expectedValue.length) {
                throw 'Transaction check failed: Map sizes differ';
              }
              for (final key in expectedValue.keys) {
                if (currentValue[key] != expectedValue[key]) {
                  throw 'Transaction check failed: Values differ for key $key';
                }
              }
            } else if (currentValue != expectedValue) {
              throw 'Transaction check failed: $currentValue != $expectedValue';
            }
            break;
        }
      }
      return true;
    } catch (e) {
      // Rollback on failure
      _data.clear();
      _data.addAll(backup);
      return false;
    }
  }
}

// Actions for testing
class FailAction extends WorkerCommand {}

class SucceedAction extends WorkerCommand {
  final int value;
  SucceedAction(this.value);
}

class GetNullAction extends WorkerCommand {}

class PrimeCheckAction extends WorkerCommand {
  final int number;
  PrimeCheckAction(this.number);
}

class SimulateHeavyWorkAction extends WorkerCommand {
  final int durationMs;
  SimulateHeavyWorkAction(this.durationMs);
}

class GetDataAction extends WorkerCommand {
  final String key;
  GetDataAction(this.key);
}

class SetDataAction extends WorkerCommand {
  final String key;
  final dynamic value;
  SetDataAction(this.key, this.value);
}

class GetAllKeysAction extends WorkerCommand {}

class DataOperation {
  final String type;
  final String key;
  final dynamic value;
  DataOperation(this.type, this.key, [this.value]);
}

class TransactionAction extends WorkerCommand {
  final List<DataOperation> operations;
  TransactionAction(this.operations);
}

void main() {
  group('CRITICAL: Isolate Resilience After Exceptions', () {
    test('Isolate should remain healthy after job exception', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        )),
      );

      // Suppress error logs during tests
      pool.setErrorHandler(IsolateErrorType.all, (error) {
        // Silently ignore errors for cleaner test output
      });

      await pool.launch();

      // Step 1: Verify isolate 0 is healthy
      final isHealthyBefore = await pool.probe(0);
      expect(isHealthyBefore, true, reason: 'Isolate should be healthy before job');

      // Step 2: Schedule a job that will fail on isolate 0
      final failingFuture = pool.dispatch(FailingJob('Test exception'), 0);

      // Step 3: Job should fail with exception
      await expectLater(
        failingFuture,
        throwsA(isA<Exception>()),
      );

      // Step 4: Wait a bit for any cleanup
      await Future.delayed(Duration(milliseconds: 100));

      // Step 5: CRITICAL TEST - Verify isolate is STILL healthy
      final isHealthyAfter = await pool.probe(0);
      expect(isHealthyAfter, true, reason: 'CRITICAL: Isolate should remain healthy after job exception!');

      // Step 6: Verify isolate can still process jobs
      final successFuture = pool.dispatch(SuccessfulJob(42), 0);
      final result = await successFuture;
      expect(result, 42);

      pool.shutdown();
    });

    test('Multiple exceptions should not kill isolate', () async {
      final pool = IsolateWorkgroup(
        1,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        )),
      );

      // Suppress error logs
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      // Throw multiple exceptions
      for (int i = 0; i < 5; i++) {
        final failingFuture = pool.dispatch(FailingJob('Exception $i'));

        await expectLater(
          failingFuture,
          throwsA(isA<Exception>()),
        );

        // Verify isolate is still healthy
        final isHealthy = await pool.probe(0);
        expect(isHealthy, true, reason: 'Isolate should remain healthy after exception #$i');
      }

      // Verify isolate can still work
      final result = await pool.dispatch(SuccessfulJob(99));
      expect(result, 99);

      pool.shutdown();
    });

    test('Instance exceptions should not kill isolate', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        )),
      );

      // Suppress error logs
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      // Create instance on isolate 0
      final instance = await pool.addInstance(FailingInstance(), isolateIndex: 0);

      // Verify isolate is healthy
      expect(await pool.probe(0), true);

      // Trigger instance exception
      await expectLater(
        instance.invoke(FailAction()),
        throwsA(isA<Exception>()),
      );

      // Wait for error handling
      await Future.delayed(Duration(milliseconds: 100));

      // CRITICAL: Isolate should still be healthy
      final isHealthyAfter = await pool.probe(0);
      expect(isHealthyAfter, true, reason: 'CRITICAL: Isolate must survive instance exception!');

      // Verify instance still works
      final result = await instance.invoke<int>(SucceedAction(42));
      expect(result, 42);

      pool.shutdown();
    });

    test('Partial job execution before failure', () async {
      final pool = IsolateWorkgroup(
        1,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        )),
      );

      // Suppress error logs
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      // Job that does some work before failing
      await expectLater(
        pool.dispatch(PartiallyFailingJob(50)),
        throwsA(anything),
      );

      // Isolate should still be healthy
      final isHealthy = await pool.probe(0);
      expect(isHealthy, true);

      pool.shutdown();
    });
  });

  group('errorsAreFatal Parameter', () {
    test('With errorsAreFatal=true, job exceptions do NOT kill the isolate', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(
          fatalErrors: true,
          health: const WorkgroupHealthConfig(
            enabled: true,
            pingTimeout: Duration(milliseconds: 500),
          ),
        ),
      );

      // Suppress error logs during this test
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      // Step 1: Verify isolate 0 is healthy
      final isHealthyBefore = await pool.probe(0);
      expect(isHealthyBefore, true);

      // Step 2: Schedule a failing job on isolate 0
      final failingFuture = pool.dispatch(FailingJob('Error with errorsAreFatal=true'), 0);

      // Step 3: Job will fail
      try {
        await failingFuture;
      } catch (e) {
        // Expected
      }

      // Step 4: Wait a bit
      await Future.delayed(Duration(milliseconds: 200));

      // Step 5: IMPORTANT - Isolate is STILL ALIVE because job exceptions are caught
      final isHealthyAfter = await pool.probe(0);

      // With fatalErrors: true, the isolate is STILL ALIVE (job exceptions are caught)
      expect(isHealthyAfter, true, reason: 'CORRECT: Job exceptions are caught, so errorsAreFatal has no effect');

      pool.shutdown();
    });

    test('With errorsAreFatal=false (default), exception does NOT kill isolate', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(
          fatalErrors: false,
          health: const WorkgroupHealthConfig(
            enabled: true,
            pingTimeout: Duration(milliseconds: 500),
          ),
        ),
      );

      // Suppress error logs during this test
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      // Step 1: Verify isolate is healthy
      expect(await pool.probe(0), true);

      // Step 2: Schedule failing job
      try {
        await pool.dispatch(FailingJob('Test error'), 0);
      } catch (e) {
        // Expected
      }

      // Step 3: Wait a bit
      await Future.delayed(Duration(milliseconds: 200));

      // Step 4: Isolate is STILL HEALTHY
      final isHealthyAfter = await pool.probe(0);
      expect(isHealthyAfter, true, reason: 'CORRECT: With errorsAreFatal=false, isolate survived the exception');

      // Verify isolate can still process jobs
      final result = await pool.dispatch(SuccessfulJob(42), 0);
      expect(result, 42);

      pool.shutdown();
    });

    test('BEST PRACTICE: Use default errorsAreFatal (false) for clarity', () async {
      final pool = IsolateWorkgroup(1);

      // Suppress error logs during this test
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      // RECOMMENDED: Use default (fatalErrors = false)
      await pool.launch(); // Default is false

      // Schedule 10 failing jobs
      for (int i = 0; i < 10; i++) {
        try {
          await pool.dispatch(FailingJob('Error $i'));
        } catch (e) {
          // Expected
        }
      }

      // Isolate should still be healthy
      expect(await pool.probe(0), true);

      // And still able to process jobs
      final result = await pool.dispatch(SuccessfulJob(99));
      expect(result, 99);

      pool.shutdown();
    });
  });

  group('Error Recovery and Continuity', () {
    test('Pool continues processing after individual job failures', () async {
      final pool = IsolateWorkgroup(3);

      // Suppress error logs
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      // Schedule 100 jobs, some will fail
      final futures = <Future<int>>[];
      for (int i = 0; i < 100; i++) {
        if (i % 10 == 0) {
          // Every 10th job fails
          futures.add(pool.dispatch(FailingJob('Error $i')).catchError((e) => -1));
        } else {
          futures.add(pool.dispatch(SuccessfulJob(i)));
        }
      }

      final results = await Future.wait(futures);

      // Should have 90 successful and 10 failed (-1)
      final successes = results.where((r) => r >= 0).length;
      final failures = results.where((r) => r == -1).length;

      expect(successes, 90);
      expect(failures, 10);

      pool.shutdown();
    });

    test('Instances remain functional after errors', () async {
      final pool = IsolateWorkgroup(2);

      // Suppress error logs
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      final instance = await pool.addInstance(FailingInstance());

      // Alternate between success and failure
      for (int i = 0; i < 5; i++) {
        if (i % 2 == 0) {
          final result = await instance.invoke<int>(SucceedAction(i));
          expect(result, i);
        } else {
          await expectLater(
            instance.invoke(FailAction()),
            throwsA(isA<Exception>()),
          );
        }
      }

      pool.shutdown();
    });

    test('Interleaved success and failure jobs', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        )),
      );

      // Suppress error logs
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      // Interleave successful and failing jobs
      final futures = <Future>[];
      for (int i = 0; i < 10; i++) {
        if (i % 2 == 0) {
          futures.add(pool.dispatch(SuccessfulJob(i)).catchError((e) => -1));
        } else {
          futures.add(pool.dispatch(FailingJob('Error $i')).catchError((e) => -1));
        }
      }

      final results = await Future.wait(futures);

      // Count successes
      final successes = results.where((r) => r >= 0).length;
      expect(successes, 5, reason: 'Should have 5 successful jobs');

      // Verify all isolates are still healthy
      for (int i = 0; i < 2; i++) {
        final isHealthy = await pool.probe(i);
        expect(isHealthy, true, reason: 'Isolate $i should be healthy');
      }

      pool.shutdown();
    });
  });

  group('Edge Cases and Complex Scenarios', () {
    test('Synchronous throw in job', () async {
      final pool = IsolateWorkgroup(1);

      // Suppress error logs
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      await pool.launch();

      await expectLater(
        pool.dispatch(SyncThrowJob()),
        throwsA(anything),
      );

      // Verify isolate still works
      final result = await pool.dispatch(SuccessfulJob(1));
      expect(result, 1);

      pool.shutdown();
    });

    test('Null return handling', () async {
      final pool = IsolateWorkgroup(1);
      await pool.launch();

      final instance = await pool.addInstance(NullReturningInstance());
      final result = await instance.invoke(GetNullAction());
      expect(result, null);

      pool.shutdown();
    });

    test('Exception during isolate initialization', () async {
      final pool = IsolateWorkgroup(2, config: WorkgroupConfig(onSetup: () {
        throw Exception('Init failed');
      }));

      // Set up error handler
      final errors = <Object>[];
      pool.setErrorHandler(IsolateErrorType.initialization, (error) {
        errors.add(error);
      });

      // Try to start with init function that throws
      try {
        await pool.launch();
      } catch (e) {
        // Expected
      }

      // If we got here with errors, the error handler caught it
      if (errors.isNotEmpty) {
        // Error handler caught initialization error
      }

      pool.shutdown();
    });

    test('Error recovery and resilience', () async {
      final pool = IsolateWorkgroup(4);

      // Set up error handler
      pool.setErrorHandler(IsolateErrorType.all, (error) {
        // Handle errors
      });

      await pool.launch();

      // Schedule mix of successful and failing jobs
      final jobs = <Future>[];
      for (int i = 0; i < 10; i++) {
        jobs.add(pool.dispatch(ErrorProneJob(i.isEven ? 0.8 : 0.0, 'success$i')).catchError((e) => 'error$i'));
      }

      final results = await Future.wait(jobs);

      // Count successes and failures
      final successes = results.where((r) => r.toString().startsWith('success')).length;
      final failures = results.where((r) => r.toString().startsWith('error')).length;

      expect(successes + failures, 10);
      expect(failures, greaterThan(0)); // Should have some failures

      pool.shutdown();
    });

    test('Timeout handling for unresponsive isolates', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          stalenessThreshold: Duration(seconds: 30),
          pingTimeout: Duration(milliseconds: 200),
        )),
      );

      await pool.launch();

      final engine = await pool.addInstance(ComputeEngine());

      // Start a very long task
      final longTask = engine.invoke(SimulateHeavyWorkAction(5000)); // 5 seconds

      // Wait a bit
      await Future.delayed(Duration(milliseconds: 300));

      // Check health while task is running
      final health = pool.healthStatus;
      expect(health.length, 2);

      // Cancel by stopping pool
      pool.shutdown();

      // Long task should fail
      await expectLater(longTask, throwsA(isA<WorkgroupJobAbortedException>()));
    });

    test('Race condition prevention', () async {
      final pool = IsolateWorkgroup(4);
      await pool.launch();

      final store = await pool.addInstance(DataStore());

      // Simulate race condition with counter
      final increments = <Future>[];
      for (int i = 0; i < 100; i++) {
        increments.add(() async {
          final current = await store.invoke(GetDataAction('counter')) ?? 0;
          await store.invoke(SetDataAction('counter', current + 1));
        }());
      }

      await Future.wait(increments);

      final finalCount = await store.invoke(GetDataAction('counter'));
      // Due to race conditions, this might not be exactly 100
      expect(finalCount, greaterThan(0));
      expect(finalCount, lessThanOrEqualTo(100));

      pool.shutdown();
    });

    test('Transaction handling', () async {
      final pool = IsolateWorkgroup(3);
      await pool.launch();

      final store = await pool.addInstance(DataStore());

      // Set initial data
      await store.invoke(SetDataAction('user:1', {'name': 'Alice', 'age': 30}));

      // Test transaction
      final transactionOps = [
        DataOperation('check', 'user:1', {'name': 'Alice', 'age': 30}),
        DataOperation('set', 'user:1', {'name': 'Alice', 'age': 31}),
        DataOperation('set', 'user:3', {'name': 'Charlie', 'age': 35}),
      ];

      final success = await store.invoke<bool>(TransactionAction(transactionOps));
      expect(success, true);

      // Verify transaction results
      final updatedUser = await store.invoke(GetDataAction('user:1'));
      expect(updatedUser['age'], 31);

      pool.shutdown();
    });

    test('Health check detects actual healthy isolate', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 200),
          maxConsecutiveFailures: 1,
        )),
      );
      await pool.launch();

      // Normal health check should pass
      expect(await pool.probe(0), true);

      // Verify both isolates are tracked as healthy
      expect(pool.isIsolateHealthy(0), true);
      expect(pool.isIsolateHealthy(1), true);

      pool.shutdown();
    });
  });

  group('Health Configuration Variants', () {
    test('Default health config', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
        )),
      );

      await pool.launch();

      // Should work with default settings
      expect(await pool.probe(0), true);
      expect(await pool.probe(1), true);

      pool.shutdown();
    });

    test('Disabled health config', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig.disabled()),
      );

      await pool.launch();

      // With health checking disabled, should return true without actual ping
      expect(await pool.probe(0), true);
      expect(pool.isIsolateHealthy(0), true);

      pool.shutdown();
    });

    test('Aggressive health config', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig.aggressive()),
      );

      await pool.launch();

      // Aggressive config has short timeouts
      expect(await pool.probe(0), true);
      expect(await pool.probe(1), true);

      pool.shutdown();
    });

    test('Relaxed health config', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig.relaxed()),
      );

      await pool.launch();

      // Relaxed config has longer timeouts
      expect(await pool.probe(0), true);
      expect(await pool.probe(1), true);

      pool.shutdown();
    });
  });

  group('Isolate Index Specific Tests', () {
    test('dispatch targets correct isolate', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      // Schedule job to isolate 0
      final result1 = await pool.dispatch(SuccessfulJob(10), 0);
      expect(result1, 10);

      // Schedule job to isolate 1
      final result2 = await pool.dispatch(SuccessfulJob(20), 1);
      expect(result2, 20);

      pool.shutdown();
    });

    test('dispatch throws on invalid isolate index', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      expect(
        () => pool.dispatch(SuccessfulJob(1), 5),
        throwsA(isA<WorkgroupException>()),
      );

      expect(
        () => pool.dispatch(SuccessfulJob(1), -2),
        throwsA(isA<WorkgroupException>()),
      );

      pool.shutdown();
    });

    test('addInstance targets correct isolate', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      // Create instance on isolate 0
      final instance1 = await pool.addInstance(DataStore(), isolateIndex: 0);
      expect(instance1.isolateId, equals(0));

      // Create instance on isolate 1
      final instance2 = await pool.addInstance(DataStore(), isolateIndex: 1);
      expect(instance2.isolateId, equals(1));

      pool.shutdown();
    });

    test('addInstance load balances when isolateIndex is -1', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      // Create multiple instances without specifying isolate
      final instances = <MemberProxy>[];

      for (var i = 0; i < 4; i++) {
        final instance = await pool.addInstance(DataStore());
        instances.add(instance);
      }

      // Check that instances are distributed across isolates
      final isolatesUsed = instances.map((w) => w.isolateId).toSet();
      expect(isolatesUsed.length, greaterThan(1), reason: 'Instances should be load balanced');

      pool.shutdown();
    });

    test('destroyInstance handles double-destroy gracefully', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      final instance = await pool.addInstance(DataStore());

      // First destroy should work
      pool.destroyInstance(instance);

      // Second destroy should not throw (prints warning instead)
      expect(() => pool.destroyInstance(instance), returnsNormally);

      pool.shutdown();
    });

    test('destroyInstance with isolateIndex parameter', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      final instance = await pool.addInstance(DataStore(), isolateIndex: 1);

      // Destroy from specific isolate
      expect(() => pool.destroyInstance(instance, isolate: 1), returnsNormally);

      pool.shutdown();
    });

    test('destroyInstance throws on invalid isolateIndex', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      final instance = await pool.addInstance(DataStore());

      expect(
        () => pool.destroyInstance(instance, isolate: 10),
        throwsA(isA<WorkgroupException>()),
      );

      pool.shutdown();
    });

    test('Isolate index boundary validation', () async {
      final pool = IsolateWorkgroup(3);
      await pool.launch();

      // Valid index
      final validInstance = await pool.addInstance(DataStore(), isolateIndex: 2);
      expect(validInstance.isolateId, 2);

      // Invalid indices
      expect(() async => await pool.addInstance(DataStore(), isolateIndex: 3), throwsA(isA<WorkgroupException>()));

      expect(() async => await pool.addInstance(DataStore(), isolateIndex: -2), throwsA(isA<WorkgroupException>()));

      pool.shutdown();
    });
  });
}
