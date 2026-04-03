---
name: zig-windows-performance
description: Optimize Zig code for Windows-first performance, safety, and predictable throughput. Use when profiling or redesigning Zig hot paths, filesystem traversal, directory enumeration, deletion pipelines, allocators, concurrency, string/path handling, Win32 interop, or any CPU/I/O-heavy CLI or service where Codex should maximize real-world performance without making the machine unstable.
---

# Zig Windows Performance

## Overview

Use this skill to improve Zig performance with a Windows-first mindset. Prioritize fewer syscalls, less allocation churn, cheaper path handling, safer Win32 interop, and concurrency that increases throughput without causing disk or scheduler thrash.

## Workflow

1. Identify the real bottleneck before changing code.
2. Optimize the hot path with the cheapest structural wins first.
3. Keep security and correctness constraints explicit.
4. Validate with benchmarks or targeted tests after each substantial change.

## Start Here

Inspect the current implementation and classify the bottleneck:

- Filesystem metadata and enumeration: read [references/windows-filesystem.md](references/windows-filesystem.md)
- Allocation, buffers, path joins, or UTF conversion: read [references/hot-paths.md](references/hot-paths.md)
- Worker counts, batching, queues, or disk contention: read [references/concurrency-io.md](references/concurrency-io.md)
- Build modes, profiling, and validation: read [references/measurement.md](references/measurement.md)

If the workload is mixed, read `measurement.md` first, then only the references needed for the hottest path.

## Core Rules

- Prefer structural wins over micro-optimizations.
- Reduce syscalls before increasing thread counts.
- Reuse buffers before introducing more allocators.
- Keep Win32 hot paths in UTF-16 when that avoids repeated conversion.
- Parallelize across independent units of work, not inside a single I/O-heavy tree by default.
- Use fixed or tightly bounded concurrency first; add adaptive logic only when benchmarks prove it is worth the complexity.
- Never trade away safety silently: keep reparse-point, symlink, junction, and dangerous-path rules explicit.

## Do / Avoid

Do:

- Measure wall-clock time, throughput, and memory together.
- Clamp concurrency for heavy Windows filesystem workloads.
- Keep progress reporting cheap and buffered, but flush explicit interactive milestones when needed.
- Treat `AccessDenied`, `FileNotFound`, and races as expected filesystem conditions when appropriate.
- Separate portability layers from Windows-specific fast paths.

Avoid:

- Assuming high CPU utilization means better performance.
- Calling expensive metadata APIs per file when enumeration already returns enough data.
- Rebuilding paths with allocation inside tight loops.
- Adding adaptive schedulers, atomics, or locks before simpler fixed policies are benchmarked.
- Using `Debug` numbers to justify production performance decisions.

## Expected Output

When using this skill, produce:

- a short diagnosis of the bottleneck
- the highest-ROI changes in implementation order
- risks to correctness or safety
- a validation plan with concrete benchmarks or tests

## Reference Map

- [references/windows-filesystem.md](references/windows-filesystem.md): Win32 enumeration, metadata, reparse handling, and directory traversal patterns
- [references/hot-paths.md](references/hot-paths.md): allocators, buffers, strings, UTF conversions, path handling, and data layout
- [references/concurrency-io.md](references/concurrency-io.md): worker strategy, batching, queues, locks, and avoiding disk thrash
- [references/measurement.md](references/measurement.md): release modes, profiling, benchmark design, and validation discipline
