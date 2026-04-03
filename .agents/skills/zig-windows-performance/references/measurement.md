# Measurement and Validation

## Build and Benchmark Rules

- Use `ReleaseFast` for performance claims unless debugging a correctness issue.
- Compare before/after on the same dataset and machine.
- Measure cold-cache and warm-cache scenarios when filesystem I/O matters.
- Record both total time and time to first useful result.

## Minimum Metrics

- wall-clock duration
- files per second
- directories per second
- bytes per second when relevant
- effective worker count
- peak memory approximation

## Good Benchmark Sets

- many small files
- few large files
- deep trees
- mixed candidate sizes
- permission failures and path races

## Validation Discipline

- Keep correctness tests for traversal and safety constraints.
- Add regression tests for new default rules, path handling, and progress behavior.
- Treat “faster but less safe” as a rejected optimization unless the product explicitly accepts that tradeoff.

## What to Say in a Review

When reviewing performance code, answer these questions explicitly:

1. What is the bottleneck: syscall, allocation, conversion, lock, or algorithm?
2. What changed in the hot path?
3. Why should it improve Windows performance specifically?
4. What safety or correctness rule could regress?
5. How will the gain be verified?
