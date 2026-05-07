# Best Practices for `isolate_workgroup`

Practical guidance, organized by topic. Each section is a small, self-contained
recipe.

## Contents

1. [Workgroup lifecycle: launch + shutdown discipline](#1-workgroup-lifecycle)
2. [Sizing the workgroup](#2-sizing-the-workgroup)
3. [`dispatch()` vs `addInstance()`: when to use which](#3-dispatch-vs-addinstance)
4. [Designing `WorkgroupJob` payloads](#4-designing-workgroupjob-payloads)
5. [Designing `WorkgroupMember` state](#5-designing-workgroupmember-state)
6. [Avoiding closure-capture pitfalls](#6-avoiding-closure-capture-pitfalls)
7. [Error handling](#7-error-handling)
8. [Health checking: when to enable](#8-health-checking-when-to-enable)
9. [Large binary payloads](#9-large-binary-payloads)
10. [Testing your jobs](#10-testing-your-jobs)

---

## 1. Workgroup lifecycle

Always pair `launch()` with `shutdown()`. The cleanest pattern is `try/finally`,
which guarantees that worker isolates and their resources are released even if
the consuming code throws.

```dart
Future<void> processBatch(List<String> urls) async {
  final workgroup = IsolateWorkgroup(4);
  try {
    await workgroup.launch();
    await Future.wait(urls.map((u) => workgroup.dispatch(FetchJob(u))));
  } finally {
    workgroup.shutdown();
  }
}
```

If you're managing a long-lived workgroup (e.g. inside a server), wire
`shutdown()` to the process-shutdown signal:

```dart
ProcessSignal.sigint.watch().listen((_) {
  workgroup.shutdown();
  exit(0);
});
```

> **Don't** create a workgroup per request. Spawning isolates is expensive
> compared to dispatching a job. Reuse one workgroup for many calls.

---

## 2. Sizing the workgroup

Pick the worker count to match the workload type, not the user's CPU count
blindly.

| Workload | Recommended size |
|---|---|
| Pure CPU (image filters, parsing) | `Platform.numberOfProcessors` |
| Mostly I/O (HTTP, disk) | 2–4× `numberOfProcessors`, capped by memory |
| Mixed | Start at `numberOfProcessors`, profile, tune |

```dart
import 'dart:io' show Platform;

final size = Platform.numberOfProcessors;
final workgroup = IsolateWorkgroup(size);
await workgroup.launch();
```

Remember: each worker has its own VM heap. A workgroup of 16 workers with 100MB
of state in each member is 1.6GB. Watch RSS, especially on mobile.

---

## 3. `dispatch()` vs `addInstance()`

Choose based on whether the work has state.

### Use `dispatch()` for stateless one-offs

When each call is independent — a hash, a parse, a transform — `dispatch()`
sends a `WorkgroupJob`, runs it on any free worker, returns the result.

```dart
class Sha256Job extends WorkgroupJob<String> {
  final String text;
  const Sha256Job(this.text);

  @override
  Future<String> execute() async {
    final bytes = utf8.encode(text);
    return sha256.convert(bytes).toString();
  }
}

final hash = await workgroup.dispatch(Sha256Job('hello'));
```

### Use `addInstance()` when state matters

When you need state to persist across calls — a cache, an open file, a model
warmed up once — `addInstance()` keeps a `WorkgroupMember` alive in a worker
and exposes a proxy you can drive with commands.

```dart
class TokenCacheMember extends WorkgroupMember {
  final _cache = <String, String>{};

  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand cmd) async {
    if (cmd is LookupCmd) return _cache[cmd.key];
    if (cmd is StoreCmd) {
      _cache[cmd.key] = cmd.value;
      return null;
    }
    throw ArgumentError('Unknown: $cmd');
  }
}

final cache = await workgroup.addInstance(TokenCacheMember());
await cache.invoke(StoreCmd('user-42', 'eyJhbGciOiJIUzI1NiJ9...'));
final token = await cache.invoke<String?>(LookupCmd('user-42'));
```

> Members are pinned to one worker. If you create one cache and want all
> calls to hit the same state, route every `invoke()` to that member.

---

## 4. Designing `WorkgroupJob` payloads

Every field on a `WorkgroupJob` is serialized and sent across the isolate
boundary. Two rules:

### 4a. Only sendable fields

Sendable types: `null`, `bool`, `int`, `double`, `String`, `List`, `Map`, `Set`
(of sendable elements), `SendPort`, `Capability`, `TransferableTypedData`,
`Type`, your own classes whose fields are also sendable.

Not sendable: `Socket`, `HttpClient`, `Database` handles, `StreamController`,
`Completer`, `ReceivePort`, anything backed by a native finalizable.

```dart
// ✅ Good — all sendable
class CsvRowJob extends WorkgroupJob<List<String>> {
  final String row;
  final String delimiter;
  const CsvRowJob(this.row, this.delimiter);

  @override
  Future<List<String>> execute() async => row.split(delimiter);
}

// ❌ Bad — Database is not sendable
class FetchUserJob extends WorkgroupJob<User> {
  final int userId;
  final Database db;        // ❌
  FetchUserJob(this.userId, this.db);
  ...
}
```

### 4b. Keep payloads small

The whole job (and its fields) is copied. A 50MB string is copied per dispatch.
For large binary blobs, use `TransferableTypedData` (see [§9](#9-large-binary-payloads)).
For a giant config object, extract just the fields you need.

```dart
// ❌ Sends whole config (incl. unused fields)
final job = RenderJob(globalConfig, templateId);

// ✅ Sends just the two fields execute() needs
final job = RenderJob(
  fontSize: globalConfig.fontSize,
  theme: globalConfig.theme,
  templateId: templateId,
);
```

---

## 5. Designing `WorkgroupMember` state

Members are mini-services living in a worker. Their state never leaves that
isolate; only command results cross the boundary.

```dart
/// In-memory inverted index for short documents.
class SearchIndexMember extends WorkgroupMember {
  final _index = <String, Set<int>>{};
  var _nextDocId = 0;

  @override
  Future<void> setup() async {}

  @override
  Future<dynamic> handle(WorkerCommand cmd) async {
    switch (cmd) {
      case AddDocCmd():
        final id = _nextDocId++;
        for (final term in cmd.text.toLowerCase().split(RegExp(r'\W+'))) {
          if (term.isEmpty) continue;
          (_index[term] ??= <int>{}).add(id);
        }
        return id;
      case SearchCmd():
        final hits = _index[cmd.term.toLowerCase()] ?? const <int>{};
        return hits.toList(growable: false);
      case StatsCmd():
        return _index.length;
      default:
        throw ArgumentError('Unknown: ${cmd.runtimeType}');
    }
  }
}

class AddDocCmd extends WorkerCommand { final String text; AddDocCmd(this.text); }
class SearchCmd extends WorkerCommand { final String term; SearchCmd(this.term); }
class StatsCmd extends WorkerCommand {}
```

Guidelines:

- **Subclass fields must be sendable** (the member is sent to the worker on
  `addInstance()`). Build large state inside `setup()` instead of in the
  constructor.
- **Override `dispose()`** to release any resources you opened in `setup()`.
- **Prefer immutable command data**. A command is just a message; treat it
  like a value, not a request handle.
- **Don't share state between members in different workers.** Each member is
  a separate state machine.

---

## 6. Avoiding closure-capture pitfalls

When you wrap work in a closure, Dart silently captures everything in the
enclosing scope, including `this` and any non-sendable fields. The validation
layer will reject the job, but errors are easier to prevent than to diagnose.

### Real-world trap: log enrichment service

A `WorkgroupJob` subclass with a function field looks innocuous, but if the
function is provided as an inline closure, all of the surrounding scope comes
along for the ride.

```dart
typedef Enricher = List<LogEvent> Function(List<LogEvent>);

class EnricherJob extends WorkgroupJob<List<LogEvent>> {
  final List<LogEvent> raw;
  final Enricher enricher;
  const EnricherJob(this.raw, this.enricher);

  @override
  Future<List<LogEvent>> execute() async => enricher(raw);
}

class LogPipeline {
  final Sink<LogEvent> _sink;          // ← not sendable
  final IsolateWorkgroup workgroup;
  LogPipeline(this.workgroup, this._sink);

  // ❌ The inline closure references _sink, so it captures `this`.
  //    `this` includes the non-sendable Sink — validation rejects the job.
  Future<List<LogEvent>> enrich(List<LogEvent> raw) {
    return workgroup.dispatch(
      EnricherJob(raw, (events) {
        final out = events.map((e) => e.copyWith(host: 'edge-1')).toList();
        _sink.add(out.last);   // 🚨 captured _sink via this!
        return out;
      }),
    );
  }
}
```

### Two safe rewrites

**Option A — pure-data job, side effects in main:**

```dart
class EnrichJob extends WorkgroupJob<List<LogEvent>> {
  final List<LogEvent> raw;
  final String host;
  const EnrichJob(this.raw, this.host);

  @override
  Future<List<LogEvent>> execute() async =>
      raw.map((e) => e.copyWith(host: host)).toList();
}

class LogPipeline {
  Future<List<LogEvent>> enrich(List<LogEvent> raw) async {
    final out = await workgroup.dispatch(EnrichJob(raw, 'edge-1'));
    _sink.add(out.last);     // side effect happens here, in main
    return out;
  }
}
```

**Option B — top-level helper passed as the enricher:**

```dart
// Top-level function — no `this` to capture.
List<LogEvent> _addEdgeHost(List<LogEvent> events) =>
    events.map((e) => e.copyWith(host: 'edge-1')).toList();

class LogPipeline {
  Future<List<LogEvent>> enrich(List<LogEvent> raw) {
    return workgroup.dispatch(EnricherJob(raw, _addEdgeHost));
  }
}
```

Top-level and `static` functions can't capture `this`. The sendability of
the arguments you bind to them is the only thing left to worry about.

---

## 7. Error handling

Worker errors arrive in the main isolate as one of the `Workgroup*Exception`
classes. Handle them at the granularity that matters:

```dart
try {
  final result = await workgroup.dispatch(ParseJob(payload));
  return result;
} on WorkgroupSetupException catch (e) {
  // The worker isolate failed to initialize — fatal for this workgroup.
  rethrow;
} on WorkgroupIsolateError catch (e) {
  // The job threw inside the worker. e.unwrappedError is your original.
  log.warning('Job failed for $payload', e.unwrappedError);
  return null;
} on WorkgroupTimeoutException catch (e) {
  log.warning('Worker exceeded ${e.timeoutMs}ms on ${e.operation}');
  return null;
}
```

For broad observability, register a typed handler:

```dart
workgroup.setErrorHandler(
  IsolateErrorType.job,
  (e) => metrics.increment('worker.job.error'),
);
```

- Catch the most specific exception you can act on.
- Don't swallow `WorkgroupSetupException` — it indicates the worker is unusable.
- Propagate `WorkgroupInactiveException` upward (your code is calling a
  shut-down workgroup).

---

## 8. Health checking: when to enable

`WorkgroupHealthConfig` controls whether the workgroup pings workers before
dispatching. There's no one-size-fits-all default.

| Scenario | Use |
|---|---|
| Short-lived CLI tool (seconds) | `WorkgroupHealthConfig.disabled()` — no overhead |
| Server, long-running, latency-sensitive | `WorkgroupHealthConfig.relaxed()` |
| Server, long-running, correctness-critical | `WorkgroupHealthConfig.aggressive()` |
| Tests | `disabled()` — deterministic timing |

```dart
final workgroup = IsolateWorkgroup(
  4,
  config: WorkgroupConfig(
    health: WorkgroupHealthConfig(
      enabled: true,
      pingTimeout: Duration(seconds: 1),
      maxConsecutiveFailures: 2,
      checkBeforeDispatching: false, // pre-dispatch check is expensive
    ),
  ),
);
```

> `checkBeforeDispatching: true` adds a ping before every dispatch. Only
> enable it if you've measured that dead-worker traffic is actually hurting
> you; for most apps the staleness threshold is enough.

---

## 9. Large binary payloads

Sending a `Uint8List` of 50MB copies all 50MB. For large binary data, use
`TransferableTypedData` — ownership transfers to the worker without copying.

```dart
class ImageThumbnailJob extends WorkgroupJob<TransferableTypedData> {
  final TransferableTypedData source;
  final int targetWidth;
  const ImageThumbnailJob(this.source, this.targetWidth);

  @override
  Future<TransferableTypedData> execute() async {
    final bytes = source.materialize().asUint8List();
    final thumb = _resize(bytes, targetWidth);     // your CPU-bound work
    return TransferableTypedData.fromList([thumb]);
  }
}

// In main:
final raw = await File('photo.jpg').readAsBytes();
final transferable = TransferableTypedData.fromList([raw]);
final out = await workgroup.dispatch(ImageThumbnailJob(transferable, 256));
final thumbnailBytes = out.materialize().asUint8List();
```

`TransferableTypedData` is single-use: once materialized in the receiving
isolate, the original is no longer accessible.

---

## 10. Testing your jobs

Three layers of tests, in increasing cost:

**1. Sendability check (cheapest, no isolates).**

```dart
import 'package:isolate_workgroup/isolate_workgroup.dart';

test('CsvRowJob payload is sendable', () {
  final job = CsvRowJob('a,b,c', ',');
  expect(canBeSentToIsolate(job), isTrue);
});
```

**2. Unit-test `execute()` directly.** It's just an async function; no workgroup
needed.

```dart
test('CsvRowJob splits row', () async {
  final result = await CsvRowJob('a,b,c', ',').execute();
  expect(result, ['a', 'b', 'c']);
});
```

**3. Integration test against a real workgroup** for end-to-end behavior.
Always shut the workgroup down in `tearDown` so subsequent tests get a clean
slate.

```dart
late IsolateWorkgroup workgroup;

setUp(() async {
  workgroup = IsolateWorkgroup(2);
  await workgroup.launch();
});

tearDown(() => workgroup.shutdown());

test('parallel csv parse', () async {
  final rows = ['a,b,c', 'd,e,f'];
  final results = await Future.wait(
    rows.map((r) => workgroup.dispatch(CsvRowJob(r, ','))),
  );
  expect(results, [
    ['a', 'b', 'c'],
    ['d', 'e', 'f'],
  ]);
});
```

---

## Summary checklist

When in doubt, walk this list:

- [ ] Wrap `launch()` / `shutdown()` in `try/finally`
- [ ] Worker count matches workload type, not just CPU count
- [ ] Stateless work → `dispatch()`; stateful → `addInstance()`
- [ ] Every job/command field is sendable
- [ ] No `this`-capturing closures inside `dispatch()` arguments
- [ ] Specific `on WorkgroupXyzException catch` rather than blanket `catch`
- [ ] Health config matches deployment profile
- [ ] Big bytes → `TransferableTypedData`
- [ ] Sendability test, unit test, integration test
