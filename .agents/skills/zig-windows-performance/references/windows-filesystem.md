# Windows Filesystem Fast Paths

## Goal

Use Windows-native enumeration and metadata to reduce per-entry cost in filesystem-heavy Zig code.

## Highest ROI Tactics

- Prefer `FindFirstFileExW` / `FindNextFileW` for Windows-specific enumeration hot paths.
- Use `FindExInfoBasic` to avoid extra short-name work.
- Use `FIND_FIRST_EX_LARGE_FETCH` when directory enumeration is the bottleneck.
- Use `WIN32_FIND_DATAW` metadata directly when it already answers the question.
- Keep traversal iterative instead of recursive when stack growth or path rebuilding becomes expensive.

## Good Patterns

- Keep the operational path in UTF-16 for Win32 calls.
- Convert root paths once, not per entry.
- Use the returned attributes to classify:
  - file
  - directory
  - reparse point
  - hidden/system when policy requires it
- Accumulate file size directly from `nFileSizeHigh/Low` when exact logical size is already exposed by enumeration.
- Skip reparse points, symlinks, and junctions unless following them is an explicit product requirement.

## Avoid

- `statFile` or equivalent per file on Windows when enumeration metadata already contains what you need.
- `openDir` or `CreateFile` only to rediscover entry type for every child.
- Rebuilding `path + "\\*"` with new allocations for every directory visit.
- Mixing UTF-8 and UTF-16 conversions repeatedly inside the inner loop.

## Use This Decision Order

1. Can enumeration metadata answer the question directly?
2. Can the path stay in UTF-16 until the end of the hot path?
3. Can traversal avoid per-entry allocation?
4. Can dangerous entries be rejected by attributes alone?

## Safety Rules

- Never follow reparse points by default.
- Treat path races and missing files as normal in large scans.
- Keep dangerous path checks outside the hot loop, but never remove them.
