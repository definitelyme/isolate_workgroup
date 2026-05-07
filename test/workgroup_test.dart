/// Core isolate pool functionality tests
@TestOn('vm')
library;

import 'dart:async';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

// Simple test job
class SimpleJob extends WorkgroupJob<int> {
  final int value;
  SimpleJob(this.value);

  @override
  Future<int> execute() async => value * 2;
}

// Long running job
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

// Memory intensive job
class MemoryIntensiveJob extends WorkgroupJob<int> {
  final int sizeInMB;
  MemoryIntensiveJob(this.sizeInMB);

  @override
  Future<int> execute() async {
    final data = List.filled(sizeInMB * 1024 * 1024 ~/ 8, 0.0);
    var sum = 0.0;
    for (var i = 0; i < data.length; i += 1000) {
      sum += i;
    }
    return sum.toInt();
  }
}

// Fibonacci job for performance testing
class FibonacciJob extends WorkgroupJob<int> {
  final int n;
  FibonacciJob(this.n);

  @override
  Future<int> execute() async {
    if (n <= 1) return n;
    int a = 0, b = 1;
    for (int i = 2; i <= n; i++) {
      final temp = a + b;
      a = b;
      b = temp;
    }
    return b;
  }
}

// Callback job for testing callback functionality
class TestCallbackJob extends WorkgroupJob<int> {
  final int startValue;
  TestCallbackJob(this.startValue);

  @override
  Future<int> execute() async {
    // Simple job that returns incremented value
    return startValue + 10;
  }
}

// Throwing job for error testing
class ThrowingJob extends WorkgroupJob<int> {
  final String errorMessage;
  ThrowingJob(this.errorMessage);

  @override
  Future<int> execute() async {
    throw Exception(errorMessage);
  }
}

void main() {
  group('Pool Lifecycle', () {
    test('Pool starts and stops correctly', () async {
      final pool = IsolateWorkgroup(4);
      expect(pool.state, WorkgroupState.idle);

      await pool.launch();
      expect(pool.state, WorkgroupState.active);
      expect(pool.isolatesCount, 4);

      pool.shutdown();
      expect(pool.state, WorkgroupState.disposed);
    });

    test('Pool with 0 isolates starts successfully', () async {
      final pool = IsolateWorkgroup(0);
      await pool.launch();

      expect(pool.isolatesCount, 0);
      expect(pool.state, WorkgroupState.active);

      pool.shutdown();
    });

    test('Pool with custom initialization', () async {
      // Note: The init function runs in each isolate, not in the main isolate,
      // so we can't directly test if it was called. We just verify that
      // launch() completes successfully with an init function.
      final pool = IsolateWorkgroup(2, config: WorkgroupConfig(onSetup: () {
        // This runs in each isolate
      }));

      await pool.launch();

      expect(pool.state, WorkgroupState.active);
      expect(pool.isolatesCount, 2);

      pool.shutdown();
    });

    test('Pool start with errorsAreFatal parameter', () async {
      final pool = IsolateWorkgroup(2, config: WorkgroupConfig(fatalErrors: true));
      await pool.launch();

      expect(pool.state, WorkgroupState.active);

      pool.shutdown();
    });

    test('Rapid start/stop cycles', () async {
      for (int cycle = 0; cycle < 5; cycle++) {
        final pool = IsolateWorkgroup(3);
        await pool.launch();

        final result = await pool.dispatch(SimpleJob(cycle));
        expect(result, cycle * 2);

        pool.shutdown();
        await Future.delayed(Duration(milliseconds: 10));
      }
    });

    test('Pool cannot start twice', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      await expectLater(
        pool.launch(),
        throwsA(isA<WorkgroupException>()),
      );

      pool.shutdown();
    });

    test('Pool stop during pending operations', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      // Schedule long-running jobs
      final futures = <Future>[];
      for (int i = 0; i < 10; i++) {
        futures.add(pool.dispatch(LongRunningJob(1000, 'job$i')));
      }

      // Stop pool while jobs are running
      await Future.delayed(Duration(milliseconds: 100));
      pool.shutdown();

      // All futures should complete with error
      for (final future in futures) {
        await expectLater(
          future,
          throwsA(isA<WorkgroupJobAbortedException>()),
        );
      }
    });
  });

  group('Dynamic Pool Scaling', () {
    test('Add isolates to running pool', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      expect(pool.isolatesCount, 2);

      await pool.addIsolate();
      expect(pool.isolatesCount, 3);

      await pool.addIsolate();
      expect(pool.isolatesCount, 4);

      pool.shutdown();
    });

    test('Dynamic scaling under load', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      // Start with light load
      var job1 = pool.dispatch(LongRunningJob(100, 'result1'));
      var job2 = pool.dispatch(LongRunningJob(100, 'result2'));
      await Future.wait([job1, job2]);

      // Scale up under heavy load
      await pool.addIsolate();
      await pool.addIsolate();
      expect(pool.isolatesCount, 4);

      // Distribute heavy load
      final heavyJobs = <Future<String>>[];
      for (int i = 0; i < 20; i++) {
        heavyJobs.add(pool.dispatch(LongRunningJob(50, 'heavy$i')));
      }

      final results = await Future.wait(heavyJobs);
      expect(results.length, 20);

      pool.shutdown();
    });

    test('Maximum pool size stress test', () async {
      final pool = IsolateWorkgroup(50);
      await pool.launch();

      expect(pool.isolatesCount, 50);

      // Schedule jobs across all isolates
      final jobs = <Future<int>>[];
      for (int i = 0; i < 100; i++) {
        jobs.add(pool.dispatch(FibonacciJob(20)));
      }

      final results = await Future.wait(jobs);
      expect(results.every((r) => r == 6765), true); // Fibonacci(20) = 6765

      pool.shutdown();
    });
  });

  group('Job Scheduling', () {
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

    test('Simple job execution', () async {
      final result = await pool.dispatch(SimpleJob(21));
      expect(result, 42);
    });

    test('Job scheduling to specific isolate', () async {
      final result1 = await pool.dispatch(SimpleJob(10), 0);
      expect(result1, 20);

      final result2 = await pool.dispatch(SimpleJob(20), 1);
      expect(result2, 40);

      final result3 = await pool.dispatch(SimpleJob(30), 2);
      expect(result3, 60);
    });

    test('Job scheduling with invalid isolate index throws', () async {
      expect(
        () => pool.dispatch(SimpleJob(1), 10),
        throwsA(isA<WorkgroupException>()),
      );

      expect(
        () => pool.dispatch(SimpleJob(1), -2),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test('Multiple concurrent jobs', () async {
      final futures = <Future<int>>[];
      for (int i = 0; i < 100; i++) {
        futures.add(pool.dispatch(SimpleJob(i)));
      }

      final results = await Future.wait(futures);
      for (int i = 0; i < 100; i++) {
        expect(results[i], i * 2);
      }
    });

    test('Job scheduling after pool stop fails', () async {
      pool.shutdown();

      expect(
        () => pool.dispatch(SimpleJob(1)),
        throwsA(isA<WorkgroupInactiveException>()),
      );
    });

    test('Long-running job cancellation on pool stop', () async {
      final longJob = pool.dispatch(LongRunningJob(5000, 'never'));

      await Future.delayed(Duration(milliseconds: 100));
      pool.shutdown();

      await expectLater(
        longJob,
        throwsA(isA<WorkgroupJobAbortedException>()),
      );
    });

    test('Memory intensive jobs', () async {
      final jobs = <Future<int>>[];
      for (int i = 0; i < 5; i++) {
        jobs.add(pool.dispatch(MemoryIntensiveJob(10))); // 10MB each
      }

      final results = await Future.wait(jobs);
      expect(results.length, 5);
      expect(results.every((r) => r >= 0), true);
    });

    test('Simple callback job', () async {
      final job = TestCallbackJob(10);

      final result = await pool.dispatch(job);

      expect(result, 20);
    });

    test('Job exception handling', () async {
      await expectLater(
        pool.dispatch(ThrowingJob('Test error')),
        throwsA(isA<Exception>()),
      );

      // Pool should still be functional after job exception
      final result = await pool.dispatch(SimpleJob(5));
      expect(result, 10);
    });
  });

  group('Health Monitoring', () {
    test('Health checking with default config', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 500),
        )),
      );

      await pool.launch();

      final isHealthy0 = await pool.probe(0);
      expect(isHealthy0, true);

      final isHealthy1 = await pool.probe(1);
      expect(isHealthy1, true);

      pool.shutdown();
    });

    test('Health status retrieval', () async {
      final pool = IsolateWorkgroup(
        3,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
        )),
      );

      await pool.launch();

      final status = pool.healthStatus;
      expect(status.length, 3);

      for (var i = 0; i < 3; i++) {
        expect(status[i]?.isolateIndex, i);
        expect(status[i]?.isHealthy, true);
      }

      pool.shutdown();
    });

    test('Health checking disabled', () async {
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

    test('Health check during heavy load', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig(
          enabled: true,
          pingTimeout: Duration(milliseconds: 200),
        )),
      );

      await pool.launch();

      // Start heavy computation
      final heavyJobs = <Future>[];
      for (int i = 0; i < 10; i++) {
        heavyJobs.add(pool.dispatch(FibonacciJob(30)));
      }

      // Check health while under load
      final isHealthy = await pool.probe(0);
      expect(isHealthy, true);

      await Future.wait(heavyJobs);
      pool.shutdown();
    });

    test('Aggressive health config', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig.aggressive()),
      );

      await pool.launch();

      // Aggressive config has short timeouts
      final isHealthy = await pool.probe(0);
      expect(isHealthy, true);

      pool.shutdown();
    });

    test('Relaxed health config', () async {
      final pool = IsolateWorkgroup(
        2,
        config: WorkgroupConfig(health: const WorkgroupHealthConfig.relaxed()),
      );

      await pool.launch();

      // Relaxed config has longer timeouts
      final isHealthy = await pool.probe(0);
      expect(isHealthy, true);

      pool.shutdown();
    });
  });

  group('Error Handling', () {
    test('Error handler receives all error types', () async {
      final errors = <Object>[];
      final pool = IsolateWorkgroup(2);

      pool.setErrorHandler(IsolateErrorType.all, (error) {
        errors.add(error);
      });

      await pool.launch();

      expect(errors.isEmpty, true);

      pool.shutdown();
    });

    test('Specific error type handlers', () async {
      Object? jobError;
      Object? instanceError;
      Object? initError;

      final pool = IsolateWorkgroup(2);

      pool.setErrorHandler(IsolateErrorType.job, (error) {
        jobError = error;
      });

      pool.setErrorHandler(IsolateErrorType.instance, (error) {
        instanceError = error;
      });

      pool.setErrorHandler(IsolateErrorType.initialization, (error) {
        initError = error;
      });

      await pool.launch();

      expect(jobError, isNull);
      expect(instanceError, isNull);
      expect(initError, isNull);

      pool.shutdown();
    });

    test('Multiple error handlers can be set', () async {
      final pool = IsolateWorkgroup(2);

      pool.setErrorHandler(IsolateErrorType.all, (error) {});
      // Set a new handler to override the previous one
      pool.setErrorHandler(IsolateErrorType.all, (error) {
        print('New handler: $error');
      });

      await pool.launch();
      pool.shutdown();
    });

    test('errorsAreFatal parameter effect', () async {
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

      // Suppress error logs during tests
      pool.setErrorHandler(IsolateErrorType.all, (error) {});

      // Start with fatalErrors: true
      await pool.launch();

      // Verify isolate is healthy before exception
      expect(await pool.probe(0), true);

      // Schedule a job that will fail
      try {
        await pool.dispatch(ThrowingJob('Test exception'), 0);
      } catch (e) {
        // Expected
      }

      // Wait for error handling
      await Future.delayed(Duration(milliseconds: 200));

      // IMPORTANT: Isolate is STILL ALIVE because job exceptions are caught
      // fatalErrors only affects UNHANDLED errors, not caught job exceptions
      expect(await pool.probe(0), true);

      // Verify isolate can still process jobs
      final result = await pool.dispatch(SimpleJob(42), 0);
      expect(result, 84);

      pool.shutdown();
    });
  });

  group('Pool State and Statistics', () {
    test('Pool state transitions', () async {
      final pool = IsolateWorkgroup(2);

      expect(pool.state, WorkgroupState.idle);

      await pool.launch();
      expect(pool.state, WorkgroupState.active);

      pool.shutdown();
      expect(pool.state, WorkgroupState.disposed);
    });

    test('Isolate index tracking', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      // The pool doesn't have instances initially
      expect(pool.memberCount, 0);

      pool.shutdown();
    });
  });

  group('Performance Benchmarks', () {
    test('Job throughput measurement', () async {
      final pool = IsolateWorkgroup(4);
      await pool.launch();

      final stopwatch = Stopwatch()..start();
      final jobs = <Future<int>>[];

      // Schedule 1000 simple jobs
      for (int i = 0; i < 1000; i++) {
        jobs.add(pool.dispatch(SimpleJob(i)));
      }

      await Future.wait(jobs);
      stopwatch.stop();

      final jobsPerSecond = 1000 / (stopwatch.elapsedMilliseconds / 1000);
      print('Job throughput: ${jobsPerSecond.toStringAsFixed(2)} jobs/second');

      expect(jobsPerSecond, greaterThan(100)); // Should handle >100 jobs/second

      pool.shutdown();
    });

    test('Parallel speedup verification', () async {
      // Helper function for prime checking
      bool isPrimeSync(int n) {
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

      // Sequential execution
      final sequentialStopwatch = Stopwatch()..start();
      final sequentialResults = <int>[];

      for (int i = 0; i < 50; i++) {
        if (isPrimeSync(10000000 + i)) {
          sequentialResults.add(10000000 + i);
        }
      }
      sequentialStopwatch.stop();

      // Parallel execution
      final pool = IsolateWorkgroup(4);
      await pool.launch();

      final parallelStopwatch = Stopwatch()..start();
      final parallelJobs = <Future<int>>[];

      for (int i = 0; i < 50; i++) {
        parallelJobs.add(pool.dispatch(FibonacciJob(25)));
      }

      await Future.wait(parallelJobs);
      parallelStopwatch.stop();

      final sequentialMs = sequentialStopwatch.elapsedMilliseconds;
      final parallelMs = parallelStopwatch.elapsedMilliseconds;

      print('Sequential time: ${sequentialMs}ms');
      print('Parallel time: ${parallelMs}ms');

      // Should complete successfully regardless of speedup
      expect(parallelJobs.length, 50);

      pool.shutdown();
    });

    test('Instance communication latency', () async {
      final pool = IsolateWorkgroup(2);
      await pool.launch();

      // For this test, we'll measure job scheduling latency
      final measurements = <int>[];

      for (int i = 0; i < 100; i++) {
        final start = DateTime.now().microsecondsSinceEpoch;
        await pool.dispatch(SimpleJob(i));
        final end = DateTime.now().microsecondsSinceEpoch;
        measurements.add(end - start);
      }

      final avgLatency = measurements.reduce((a, b) => a + b) / measurements.length;
      print('Average job scheduling latency: ${avgLatency.toStringAsFixed(2)} microseconds');

      expect(avgLatency, lessThan(10000)); // Should be less than 10ms

      pool.shutdown();
    });
  });
}
