# Contributing to isolate_workgroup

Thanks for taking the time to contribute. This document explains how to set
up the project locally, the conventions to follow, and the process for
submitting changes.

## Getting started

### Prerequisites

- Dart SDK `>=3.0.0 <4.0.0`
- Git

### Setup

```bash
git clone git@github.com:definitelyme/isolate_workgroup.git
cd isolate_workgroup
dart pub get
```

To work on the example app:

```bash
cd example
dart pub get
```

## Development workflow

### Running tests

The full test suite must pass on every PR.

```bash
dart test
```

### Static analysis

```bash
dart analyze
```

The CI configuration treats analyzer warnings as errors. Fix them locally
before pushing.

### Formatting

```bash
dart format .
```

Run this before committing. Unformatted code will be flagged in review.

## Submitting a change

1. **Open an issue first** for any non-trivial change. This avoids duplicated
   work and gives a chance to discuss the design before code is written.
   Trivial fixes (typos, doc tweaks, obvious bugs) can skip this step.
2. **Branch from `main`.** Use a descriptive name, e.g.
   `feat/health-check-jitter` or `fix/kill-leaks-handles`.
3. **Write tests.** Every feature change should include tests that exercise
   the new behavior. Bug fixes should include a regression test.
4. **Keep commits focused.** One logical change per commit. Squash WIP
   commits before opening the PR.
5. **Update docs.** If your change affects the public API, update the
   relevant doc comments, the README, and `CHANGELOG.md`.
6. **Open the PR.** Describe what changed and why. Link the issue. Make sure
   CI passes.

### Commit message format

Follow the
[Conventional Commits](https://www.conventionalcommits.org/) prefix style:

```
<type>: <subject>

<body — optional, explains the why>
```

Common types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `perf`.

## Code style

- Public APIs must have doc comments. Use `///` and reference related types
  in square brackets, e.g. `[IsolateWorkgroup.dispatch]`.
- Prefer composition over inheritance. The package already has clear
  abstractions (`WorkgroupJob`, `WorkgroupMember`, `WorkerCommand`) — extend
  them rather than introducing parallel hierarchies.
- Errors should be specific. Throw the most precise exception class from
  `lib/src/exceptions.dart`. Add a new one if none fit.
- Avoid `dynamic` in public signatures. Use generics or specific types.
- Keep files focused. If a file exceeds ~600 lines, consider splitting it.

## Reporting bugs

Open an issue with:

- Dart SDK version (`dart --version`)
- Platform (macOS / Linux / Windows)
- A minimal reproduction
- The expected vs. actual behavior
- The full stack trace if available

## Reporting security issues

Do **not** open a public issue for security-sensitive bugs. Email the
maintainer privately first.

## Licensing of contributions

By submitting a contribution you agree that it will be licensed under the
project's BSD-3-Clause license (see `LICENSE`). Make sure you have the right
to submit the contribution — i.e. you wrote it yourself, or it was already
under a compatible license and you have made any required attribution
explicit in the contribution.
