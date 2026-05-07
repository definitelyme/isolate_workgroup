import 'dart:async';

import '../workgroup_member.dart';

export 'extensions.dart';
export 'external_job.dart';
export 'messages.dart';
export 'worker.dart';

// Global counter for request IDs
int requestIdCounter = 0;

// Global counter for member IDs
int instanceIdCounter = 0;

// Global map of worker members inside worker isolates
Map<int, WorkgroupMember> workerInstances = {};

// Global map of request completers inside worker isolates
Map<int, Completer> isolateRequestCompleters = {};
