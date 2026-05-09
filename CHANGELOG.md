## 1.0.0

Initial public release. A dynamic pool of worker isolates for parallel
processing in Dart, forked and rebranded from [`isolate_pool_2`].

### Highlights

- **`IsolateWorkgroup`** — top-level pool with `launch()`, `dispatch()`,
  `addInstance()`, `kill()`, `addIsolate()`, `shutdown()`, `probe()`,
  and typed error handlers via `setErrorHandler(IsolateErrorType.…)`.
- **`WorkgroupJob<E>`** — one-off jobs with `Future<E> execute()`.
- **`WorkgroupMember` + `MemberProxy<T>`** — persistent stateful
  workers addressed by proxy, with `setup()` / `handle()` / `dispose()`
  lifecycle and `WorkerCommand`-based RPC.
- **`CallbackWorkgroup<R, A>`** — single-shot job with `report(arg)`
  progress callbacks.
- **`WorkgroupHealthConfig`** — `disabled` / `aggressive` / `relaxed`
  presets, plus per-field tuning of ping timeouts, staleness, failure
  thresholds, and pre-dispatch checks.
- **`WorkgroupConfig`** — bundles `onSetup`, `fatalErrors`,
  `labelBuilder`, `startupPolicy` (`concurrent` / `sequential`), and
  health config.
- **9 typed exceptions** — `WorkgroupException`,
  `WorkgroupInactiveException`, `WorkgroupJobAbortedException`,
  `WorkgroupNotReadyException`, `WorkgroupSetupException`,
  `WorkgroupTimeoutException`, `WorkgroupMemberNotFoundException`,
  `WorkgroupMemberDeadException`, `InvalidWorkgroupResponseException`.
- **Validation helpers** — `canBeSentToIsolate(obj)` and the
  `WorkgroupMemberValidation` extension.

### Documentation

- README with hero animation, API cheatsheet, and architecture diagram.
- [`BEST_PRACTICES.md`](BEST_PRACTICES.md) — sizing, payload design,
  closure-capture pitfalls, error handling, health-check tuning, and
  large-binary transfers.
- [`example/example.dart`](example/example.dart) — parallel reduce and
  stateful counter samples.

[`isolate_pool_2`]: https://github.com/maxim-saplin/isolate_pool_2
