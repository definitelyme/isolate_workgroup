# Isolate Workgroup

A library for managing isolates in a workgroup for parallel processing in Dart applications.

This library provides a simple API for creating and managing a workgroup of isolates,
scheduling one-off jobs, and creating persistent members in isolates.

## Features

- Create and manage a workgroup of isolates
- Schedule one-off jobs to be executed in the workgroup
- Create persistent members in isolates for stateful processing
- Communication between main isolate and worker isolates
- Support for progress reporting from worker isolates

## Usage

### Basic Usage

The workgroup can accept one-time requests (workgroup jobs) mimicking Flutter's `compute()` method. But instead of spawning a new isolate each time it will use one of the available active isolates from the workgroup. In order to do so you need to inherit `WorkgroupJob` class, define whatever params are needed as class fields, override the `execute()` method that will be executed on a workgroup isolate. Use `IsolateWorkgroup.dispatch()` and pass an instance of a workgroup job in order to get it transferred to another isolate, executed and result returned.

```dart
import 'package:isolate_workgroup/isolate_workgroup.dart';

void main() async {
  // Create a workgroup with 4 isolates
  final pool = IsolateWorkgroup(4);
  
  // Start the workgroup
  await pool.launch();
  
  // Dispatch a job
  final result = await pool.dispatch(MyJob());
  
  // Stop the workgroup when done
  pool.shutdown();
}

// Define a job
class MyJob extends WorkgroupJob<String> {
  @override
  Future<String> execute() async {
    // Perform work in isolate
    return 'Result from isolate';
  }
}
```

### Persistent Members

The second way of using the APIs is to have a member created in one of the workgroup isolates and communicate with it via a proxy instance. It is kind of messaging from the main isolate to one of the isolates in a workgroup with multiple members created in multiple isolates, messages and responses properly correlated and arranged via descendants of `WorkerCommand`. You can wrap `MemberProxy` in a class and mimic RPC kind of communication with `WorkgroupMember` in external isolate.

```dart
import 'package:isolate_workgroup/isolate_workgroup.dart';

void main() async {
  final pool = IsolateWorkgroup(4);
  await pool.launch();
  
  // Create a persistent member
  final proxy = await pool.addInstance(MyMember());
  
  // Call methods on the member
  final result = await proxy.invoke(MyAction('parameter'));
  
  pool.shutdown();
}

// Define a member
class MyMember extends WorkgroupMember {
  @override
  Future<void> setup() async {
    // Initialize resources, load data, etc.
  }
  
  @override
  Future<dynamic> handle(WorkerCommand action) async {
    if (action is MyAction) {
      return 'Processed: ${action.parameter}';
    }
    return null;
  }
}

// Define actions
class MyAction extends WorkerCommand {
  final String parameter;
  
  MyAction(this.parameter);
}
```

#### WorkgroupMember Architecture Overview

```dart
                                                           │
                        Main isolate                       │  Isolate in the workgroup
                                                           │
                        ┌─────────────────────────────┐    │
Step 1 - Instantiate    │                             │    │     Workgroup member with params
a descendant of         │  WorkgroupMember            │    │     is passed to isolate within
WorkgroupMember         │                             │    │     the workgroup. setup() method is
                        │    - Params                 │    │     called initializing whatever
                        │                             │    │     fields necessary and creating
                        └──────────────┬──────────────┘    │     whatever objects required
                                       │                   │     (aka State)
                                   Passed to               │
                                       │                   │   ┌─────────────────────────────┐
                                       │                   │   │                             │
                        ┌──────────────┼──────────────┐    │   │  WorkgroupMember            │
Step 2 - Pass the       │              │              │    │   │                             │
WorkgroupMember to      │  IsolateWorkgroup            │    │   │    - Params                 │
isolate workgroup, it   │              ▼         ┌────┼────┼───►        ▼                    │
will transfer the       │    - addInstance()──┘    │    │   │    - setup()──┐             │
object (together with   │                             │    │   │               │             │
fields) to isolate and  └──────────────┬──────────────┘    │   │    - State ◄──┘             │
call setup(). Returned                 │                   │   │                             │
                                    Returns                │   │    - handle()               │
                                       │                   │   │              ▲              │
                                       │                   │   └──────────────┬──────────────┘
                        ┌──────────────▼──────────────┐    │                  │
Step 3 - use returned   │                             │    │                  │
MemberProxy             │  MemberProxy                │    │                  │
which can be used to    │                             │    │
pass actions to the     │    - invoke() ◄─────────────┼────┼──────────────────┘
member in the workgroup │                             │    │
                        └──────────────▲──────────────┘    │
                                       │                   │      WorkerCommand descendants are
                                       │                   │      passed to isolates via proxy
                                       │                   │      instance in the main isolate.
                                       │                   │      Workgroup member uses switch
                        ┌──────────────┴──────────────┐    │      statement in handle()
Create a set of         │                             │    │      processing requests and returning
WorkerCommand           │  WorkerCommand              │    │      results back to the requester
descendants             │                             │    │
defining workgroup      │    - Params                 │    │
member capabilities,    │                             │    │
use them with           └─────────────────────────────┘    │
invoke()                                                   │
```

## License

BSD 3-Clause. See [`LICENSE`](LICENSE) for the full text.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup, workflow, and code-style
guidelines.
