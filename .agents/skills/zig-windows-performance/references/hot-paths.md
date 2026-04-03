# Hot Path Design in Zig

## Priority Order

1. Remove syscalls.
2. Remove allocations.
3. Remove conversions.
4. Reduce synchronization.
5. Only then consider lower-level micro-tuning.

## Buffers and Allocators

- Use reusable worker-local buffers for paths, search patterns, and temporary frames.
- Prefer `ArrayListUnmanaged`, fixed buffers, arenas, or explicit slices when lifetime is obvious.
- Keep `GeneralPurposeAllocator` out of the tight loop when possible.
- Grow buffers amortized, not one path fragment at a time.

## Strings and Paths

- Avoid `std.fs.path.join` in the hot path when a mutable path buffer is enough.
- Avoid `dupe` per entry.
- Distinguish:
  - display path for logs or UI
  - operational path for system calls
- On Windows, keep the operational path in UTF-16 when calling Win32 APIs repeatedly.

## Data Layout

- Prefer contiguous arrays over pointer-heavy structures for queues and frame stacks.
- Keep per-item structs compact and stable.
- Batch publication of results instead of taking locks on every item.

## Avoid

- Allocating new buffers for each directory or file.
- Using convenience abstractions that hide repeated copies in hot code.
- Premature inlining games without evidence.
- Adding caching layers before understanding whether the workload is streaming or reuse-heavy.
