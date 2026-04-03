# Concurrency and I/O Discipline

## Principle

Use more CPU only when it increases throughput. On Windows filesystem workloads, too many workers often reduce performance by increasing seek pressure, cache churn, lock contention, and scheduler overhead.

## Recommended Strategy

- Parallelize across independent candidates, roots, or work items.
- Avoid nested thread pools.
- Keep one scheduler responsible for the expensive phase.
- Start with a fixed clamp for Windows I/O-heavy work.
- Separate light and heavy work when a cheap heuristic is available.

## Good Heuristics

- Discovery:
  - more parallelism is often acceptable
- Sizing/removal on large trees:
  - use a smaller fixed concurrency cap
- Heavy trees:
  - do not process too many simultaneously
- Small independent tasks:
  - process earlier for faster visible progress

## Progress Reporting

- Report candidate-level or item-level milestones.
- Flush explicitly only when the user needs real-time visibility.
- Avoid noisy per-directory heartbeats unless a long-running task has no other signal.

## Avoid

- Tying worker count directly to CPU core count for disk-bound workloads.
- Adaptive schedulers as a first implementation.
- Locking around every completed file or directory.
- Publishing progress so often that reporting itself becomes measurable work.

## Safe Aggression

- It is acceptable to use more CPU and RAM if:
  - the machine remains responsive
  - disk thrash does not dominate
  - latency to first useful result improves
  - the total wall-clock time actually drops
