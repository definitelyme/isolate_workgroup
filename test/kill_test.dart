/// kill() lifecycle tests with tightened canonical error messages.
/// Spec §7.6.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:isolate_workgroup/isolate_workgroup.dart';
import 'package:test/test.dart';

import '_support/jobs.dart';
import '_support/members.dart';
import '_support/probes.dart';

class _IsolateIdJob extends WorkgroupJob<int> {
  @override
  Future<int> execute() async => Isolate.current.hashCode;
}

void main() {
  group('IsolateWorkgroup.kill()', () {
    late IsolateWorkgroup wg;

    setUp(() {
      // Each test creates its own workgroup; tearDown shuts it down if alive.
    });

    tearDown(() {
      if (wg.state != WorkgroupState.disposed) {
        wg.shutdown();
      }
    });

    test('removes the isolate and rejects further dispatch to it', () async {
      wg = IsolateWorkgroup(4);
      await wg.launch();
      expect(wg.isolatesCount, 4);

      wg.kill(2);
      // isolatesCount stays the same for index stability.
      expect(wg.isolatesCount, 4);
      expect(wg.liveIsolateCount, 3);

      expect(
        () => wg.dispatch(EchoJob<int>(10), 2),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test(
      'caught: pending job on killed isolate fails with canonical message',
      () async {
        wg = IsolateWorkgroup(3);
        await wg.launch();

        final fut = wg.dispatch(SleepJob(5000, 'never'), 1);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        wg.kill(1);

        await expectLater(
          fut,
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            equals('Isolate #1 was killed - job cancelled'),
          )),
        );
      },
    );

    test(
      'unhandled: pending job on killed isolate surfaces to runZonedGuarded',
      () async {
        wg = IsolateWorkgroup(3);
        await wg.launch();

        final (err, _) = await captureUnhandled(() {
          // ignore: unawaited_futures
          wg.dispatch(SleepJob(5000, 'never'), 1);
          // Schedule kill in a microtask so the dispatch is in-flight.
          Timer(const Duration(milliseconds: 100), () {
            wg.kill(1);
          });
        }, timeout: const Duration(seconds: 3));
        expect(err, isA<WorkgroupException>());
        expect(
          (err as WorkgroupException).message,
          equals('Isolate #1 was killed - job cancelled'),
        );
      },
    );

    test('destroys all instances on the killed isolate', () async {
      wg = IsolateWorkgroup(3);
      await wg.launch();

      final p0 = await wg.addInstance(EchoMember(), isolateIndex: 0);
      final p1a = await wg.addInstance(EchoMember(), isolateIndex: 1);
      final p1b = await wg.addInstance(EchoMember(), isolateIndex: 1);
      final p2 = await wg.addInstance(EchoMember(), isolateIndex: 2);

      expect(wg.memberCount, 4);

      wg.kill(1);
      expect(wg.memberCount, 2);
      expect(wg.members.containsKey(p0.memberId), isTrue);
      expect(wg.members.containsKey(p1a.memberId), isFalse);
      expect(wg.members.containsKey(p1b.memberId), isFalse);
      expect(wg.members.containsKey(p2.memberId), isTrue);
    });

    test('other isolates continue to work normally', () async {
      wg = IsolateWorkgroup(4);
      await wg.launch();

      final j0 = wg.dispatch(EchoJob<int>(5), 0);
      final j2 = wg.dispatch(EchoJob<int>(10), 2);
      final j3 = wg.dispatch(EchoJob<int>(15), 3);

      wg.kill(1);

      expect(await j0, 5);
      expect(await j2, 10);
      expect(await j3, 15);

      expect(await wg.dispatch(EchoJob<int>(99), 0), 99);
    });

    test(
      'invalid isolate index throws with canonical exact-match message',
      () async {
        wg = IsolateWorkgroup(3);
        await wg.launch();

        expect(
          () => wg.kill(-1),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            equals('Invalid isolate index -1. Valid indices are 0...2'),
          )),
        );
        expect(
          () => wg.kill(3),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            equals('Invalid isolate index 3. Valid indices are 0...2'),
          )),
        );
        expect(
          () => wg.kill(100),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            equals('Invalid isolate index 100. Valid indices are 0...2'),
          )),
        );
      },
    );

    test(
      'killing an already-killed isolate throws with canonical exact-match message',
      () async {
        wg = IsolateWorkgroup(3);
        await wg.launch();
        wg.kill(1);

        expect(
          () => wg.kill(1),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            equals(
              'Isolate at index 1 does not exist or has already been removed',
            ),
          )),
        );
      },
    );

    test('killing on idle workgroup throws WorkgroupException', () async {
      wg = IsolateWorkgroup(3);
      // Note: launch not called.
      expect(
        () => wg.kill(0),
        throwsA(isA<WorkgroupException>()),
      );
    });

    test(
      'killing on disposed workgroup throws WorkgroupInactiveException',
      () async {
        wg = IsolateWorkgroup(3);
        await wg.launch();
        wg.shutdown();
        expect(
          () => wg.kill(0),
          throwsA(isA<WorkgroupInactiveException>()),
        );
      },
    );

    test('multiple kills work correctly', () async {
      wg = IsolateWorkgroup(5);
      await wg.launch();

      final p0 = await wg.addInstance(EchoMember(), isolateIndex: 0);
      await wg.addInstance(EchoMember(), isolateIndex: 1);
      final p2 = await wg.addInstance(EchoMember(), isolateIndex: 2);
      await wg.addInstance(EchoMember(), isolateIndex: 3);
      final p4 = await wg.addInstance(EchoMember(), isolateIndex: 4);

      wg.kill(1);
      wg.kill(3);
      expect(wg.memberCount, 3);
      expect(wg.members.containsKey(p0.memberId), isTrue);
      expect(wg.members.containsKey(p2.memberId), isTrue);
      expect(wg.members.containsKey(p4.memberId), isTrue);
    });

    test('cleans _isolateHealth, _isolateBusyWithJob, and all 3 port maps',
        () async {
      wg = IsolateWorkgroup(3);
      await wg.launch();

      // Force entries into _isolateBusyWithJob via dispatch.
      await wg.dispatch(EchoJob<int>(1), 1);
      // Health entry should exist.
      expect(wg.healthStatus.containsKey(1), isTrue);

      wg.kill(1);

      // Health entry removed.
      expect(wg.healthStatus.containsKey(1), isFalse);
      // All 3 port maps no longer reference this isolate.
      expectIsolatePortsRemoved(wg, 1);
    });

    test('isolate indices remain stable after kill', () async {
      wg = IsolateWorkgroup(4);
      await wg.launch();

      final id0 = await wg.dispatch(_IsolateIdJob(), 0);
      final id2 = await wg.dispatch(_IsolateIdJob(), 2);
      final id3 = await wg.dispatch(_IsolateIdJob(), 3);

      wg.kill(1);

      expect(await wg.dispatch(_IsolateIdJob(), 0), id0);
      expect(await wg.dispatch(_IsolateIdJob(), 2), id2);
      expect(await wg.dispatch(_IsolateIdJob(), 3), id3);
    });

    test(
      'rapid sequential kills leave the surviving isolates functional',
      () async {
        wg = IsolateWorkgroup(5);
        await wg.launch();

        wg.kill(0);
        wg.kill(2);
        wg.kill(4);

        expect(await wg.dispatch(EchoJob<int>(100), 1), 100);
        expect(await wg.dispatch(EchoJob<int>(200), 3), 200);

        expect(
          () => wg.dispatch(EchoJob<int>(1), 0),
          throwsA(isA<WorkgroupException>()),
        );
        expect(
          () => wg.dispatch(EchoJob<int>(1), 2),
          throwsA(isA<WorkgroupException>()),
        );
        expect(
          () => wg.dispatch(EchoJob<int>(1), 4),
          throwsA(isA<WorkgroupException>()),
        );
      },
    );

    test(
      'addInstance to a killed isolate throws with canonical message',
      () async {
        wg = IsolateWorkgroup(3);
        await wg.launch();
        wg.kill(1);

        await expectLater(
          wg.addInstance(EchoMember(), isolateIndex: 1),
          throwsA(isA<WorkgroupException>().having(
            (e) => e.message,
            'message',
            contains('killed or does not exist'),
          )),
        );

        // Other isolates are unaffected.
        final p0 = await wg.addInstance(EchoMember(), isolateIndex: 0);
        final p2 = await wg.addInstance(EchoMember(), isolateIndex: 2);
        expect(wg.members.containsKey(p0.memberId), isTrue);
        expect(wg.members.containsKey(p2.memberId), isTrue);
      },
    );

    test(
      'tracks alive isolate count correctly with kills + addIsolate',
      () async {
        wg = IsolateWorkgroup(5);
        await wg.launch();

        expect(wg.isolatesCount, 5);
        expect(wg.liveIsolateCount, 5);

        wg.kill(2);
        expect(wg.isolatesCount, 5);
        expect(wg.liveIsolateCount, 4);

        wg.kill(0);
        wg.kill(4);
        expect(wg.isolatesCount, 5);
        expect(wg.liveIsolateCount, 2);

        await wg.addIsolate();
        expect(wg.isolatesCount, 6);
        expect(wg.liveIsolateCount, 3);
      },
    );

    test(
      'killing while another isolate is processing keeps that one healthy',
      () async {
        wg = IsolateWorkgroup(2);
        await wg.launch();

        // Schedule a slow job on isolate 0, then kill isolate 1.
        final slowFut = wg.dispatch(SleepJob(500, 'survived'), 0);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        wg.kill(1);

        // Slow job on isolate 0 must still complete.
        expect(await slowFut, 'survived');
        expect(wg.liveIsolateCount, 1);
      },
    );
  });
}
