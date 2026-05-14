use anyhow::{Context, Result};
use application::{CleanerPort, ScanProgressPort, ScanProgressSnapshot, ScannerPort};
use domain::{
    AppLearningState, CandidateEntry, CleanRequest, CleanResult, GarbageRules, ScanMode,
    ScanRequest,
};
use rayon::prelude::*;
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::thread;
use std::time::Duration;
use walkdir::WalkDir;

use crate::{is_system_excluded, is_system_protected_name};

pub struct NativeScanner;
pub struct NativeCleaner;

impl ScannerPort for NativeScanner {
    fn scan(
        &self,
        request: &ScanRequest,
        learning: &AppLearningState,
        progress: Option<&dyn ScanProgressPort>,
    ) -> Result<Vec<CandidateEntry>> {
        let pending = discover_candidates(request, learning, progress)?;
        if request.mode == ScanMode::Fast {
            return Ok(pending
                .into_iter()
                .map(|p| CandidateEntry {
                    path: p.path,
                    bytes: 0,
                    kind: p.kind,
                    selected: true,
                })
                .collect());
        }

        let out = pending
            .into_par_iter()
            .map(|p| -> Result<CandidateEntry> {
                let size = dir_size(&p.path)?;
                Ok(CandidateEntry {
                    path: p.path,
                    bytes: size,
                    kind: p.kind,
                    selected: true,
                })
            })
            .collect::<Result<Vec<_>>>()?;

        Ok(out)
    }
}

struct PendingCandidate {
    path: std::path::PathBuf,
    kind: String,
}

fn discover_candidates(
    request: &ScanRequest,
    learning: &AppLearningState,
    progress: Option<&dyn ScanProgressPort>,
) -> Result<Vec<PendingCandidate>> {
    #[cfg(windows)]
    {
        discover_windows_native(request, learning, progress)
    }
    #[cfg(not(windows))]
    {
        discover_walkdir(request, learning, progress)
    }
}

#[cfg(not(windows))]
fn discover_walkdir(
    request: &ScanRequest,
    learning: &AppLearningState,
    progress: Option<&dyn ScanProgressPort>,
) -> Result<Vec<PendingCandidate>> {
    let rules = if !request.active_targets.is_empty() {
        GarbageRules::new(&request.active_targets, &[])
    } else {
        GarbageRules::new(&learning.base_targets, &learning.custom_targets)
    };
    let mut out = Vec::new();
    let mut visited_dirs = 0usize;
    let mut matched_dirs = 0usize;
    let mut iter = WalkDir::new(&request.root).follow_links(false).into_iter();
    loop {
        let entry = match iter.next() {
            None => break,
            Some(Err(_)) => continue,
            Some(Ok(e)) => e,
        };
        if !entry.file_type().is_dir() {
            continue;
        }
        let path = entry.path();
        if is_system_excluded(path, &request.excluded_roots) {
            iter.skip_current_dir();
            continue;
        }
        if let Some(p) = progress {
            while p.is_paused() {
                thread::sleep(Duration::from_millis(30));
            }
        }
        visited_dirs += 1;
        if let Some(kind) = rules.matches_dir_name(path) {
            matched_dirs += 1;
            out.push(PendingCandidate {
                path: path.to_path_buf(),
                kind,
            });
            iter.skip_current_dir();
        }
        if visited_dirs % 128 == 0 {
            if let Some(p) = progress {
                p.on_progress(ScanProgressSnapshot { visited_dirs, matched_dirs });
            }
        }
    }
    if let Some(p) = progress {
        p.on_progress(ScanProgressSnapshot { visited_dirs, matched_dirs });
    }
    Ok(out)
}

#[cfg(windows)]
fn discover_windows_native(
    request: &ScanRequest,
    learning: &AppLearningState,
    progress: Option<&dyn ScanProgressPort>,
) -> Result<Vec<PendingCandidate>> {
    use std::ffi::OsString;
    use std::os::windows::ffi::{OsStrExt, OsStringExt};
    use windows_sys::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::Storage::FileSystem::{
        FILE_ATTRIBUTE_DIRECTORY, FILE_ATTRIBUTE_REPARSE_POINT, FIND_FIRST_EX_LARGE_FETCH,
        FindClose, FindExInfoBasic, FindExSearchNameMatch, FindFirstFileExW, FindNextFileW,
        WIN32_FIND_DATAW,
    };

    fn join_pattern(path: &std::path::Path) -> Vec<u16> {
        let mut s = path.as_os_str().encode_wide().collect::<Vec<_>>();
        if !s.ends_with(&['\\' as u16]) {
            s.push('\\' as u16);
        }
        s.push('*' as u16);
        s.push(0);
        s
    }

    fn decode_name(file_name: &[u16]) -> String {
        let nul = file_name.iter().position(|&c| c == 0).unwrap_or(file_name.len());
        OsString::from_wide(&file_name[..nul]).to_string_lossy().to_string()
    }

    let rules = if !request.active_targets.is_empty() {
        GarbageRules::new(&request.active_targets, &[])
    } else {
        GarbageRules::new(&learning.base_targets, &learning.custom_targets)
    };
    let mut out = Vec::new();
    let mut stack = vec![request.root.clone()];
    let mut visited_dirs = 0usize;
    let mut matched_dirs = 0usize;

    while let Some(current) = stack.pop() {
        if is_system_excluded(&current, &request.excluded_roots) {
            continue;
        }
        if let Some(progress) = progress {
            while progress.is_paused() {
                thread::sleep(Duration::from_millis(30));
            }
        }
        visited_dirs += 1;
        let pattern = join_pattern(&current);
        let mut data = WIN32_FIND_DATAW::default();
        let handle: HANDLE = unsafe {
            FindFirstFileExW(
                pattern.as_ptr(),
                FindExInfoBasic,
                &mut data as *mut _ as *mut _,
                FindExSearchNameMatch,
                std::ptr::null(),
                FIND_FIRST_EX_LARGE_FETCH,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            continue;
        }

        loop {
            let name = decode_name(&data.cFileName);
            if name != "." && name != ".." {
                let attrs = data.dwFileAttributes;
                let is_dir = (attrs & FILE_ATTRIBUTE_DIRECTORY) != 0;
                let is_reparse = (attrs & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                if is_dir && !is_reparse && !is_system_protected_name(&name) {
                    let mut child = current.clone();
                    child.push(&name);
                    if let Some(kind) = rules.matches_dir_name(&child) {
                        matched_dirs += 1;
                        out.push(PendingCandidate {
                            path: child,
                            kind,
                        });
                    } else {
                        stack.push(child);
                    }
                }
            }
            let next = unsafe { FindNextFileW(handle, &mut data) };
            if next == 0 {
                break;
            }
        }
        if visited_dirs % 128 == 0 {
            if let Some(progress) = progress {
                progress.on_progress(ScanProgressSnapshot {
                    visited_dirs,
                    matched_dirs,
                });
            }
        }
        unsafe {
            FindClose(handle);
        }
    }
    if let Some(progress) = progress {
        progress.on_progress(ScanProgressSnapshot {
            visited_dirs,
            matched_dirs,
        });
    }

    Ok(out)
}

impl CleanerPort for NativeCleaner {
    fn clean(&self, request: &CleanRequest) -> Result<CleanResult> {
        let mut removed_count = 0usize;
        let mut removed_bytes = 0u64;
        let mut removed_paths = Vec::new();
        let scan_root = request
            .scan_root
            .canonicalize()
            .with_context(|| format!("invalid scan root: {:?}", request.scan_root))?;

        // Build a lookup table of pre-computed sizes so we can skip dir_size when
        // the caller already measured the tree during scanning.
        let size_hint: HashMap<PathBuf, u64> = request
            .selected_paths
            .iter()
            .zip(
                request
                    .selected_bytes
                    .iter()
                    .copied()
                    .chain(std::iter::repeat(0)),
            )
            .filter(|(_, b)| *b > 0)
            .map(|(p, b)| (p.clone(), b))
            .collect();

        // Sort deepest-first so a child is deleted before its parent when both
        // are in the selection, avoiding a "path no longer exists" error on the
        // parent (which was already partially cleaned).
        let mut paths = request.selected_paths.clone();
        paths.sort_by_key(|p| usize::MAX - p.as_os_str().len());

        for path in paths {
            if !path.exists() {
                continue;
            }
            let canonical = path
                .canonicalize()
                .with_context(|| format!("invalid path: {:?}", path))?;
            if !is_safe_delete_target(&scan_root, &canonical) {
                continue;
            }
            if !canonical.is_dir() {
                continue;
            }
            // Use the pre-computed size when available; fall back to a dir walk
            // only when the caller did not provide one (e.g. Fast-mode scans).
            let bytes = match size_hint.get(&path).copied() {
                Some(b) if b > 0 => b,
                _ => dir_size(&path).unwrap_or(0),
            };
            fs::remove_dir_all(&canonical)
                .with_context(|| format!("failed to remove {:?}", canonical))?;
            removed_count += 1;
            removed_bytes += bytes;
            removed_paths.push(path.clone());
        }
        Ok(CleanResult {
            removed_count,
            removed_bytes,
            removed_paths,
        })
    }
}

fn dir_size(path: &Path) -> Result<u64> {
    let mut total = 0u64;
    for entry in WalkDir::new(path).follow_links(false).into_iter().filter_map(Result::ok) {
        if entry.file_type().is_file() {
            let meta = entry.metadata()?;
            total = total.saturating_add(meta.len());
        }
    }
    Ok(total)
}

fn is_safe_delete_target(scan_root: &Path, candidate: &Path) -> bool {
    if candidate == scan_root {
        return false;
    }
    if !candidate.starts_with(scan_root) {
        return false;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::tempdir;

    fn req(scan_root: PathBuf, paths: Vec<PathBuf>) -> CleanRequest {
        CleanRequest { scan_root, selected_paths: paths, selected_bytes: vec![] }
    }

    fn req_with_bytes(scan_root: PathBuf, paths: Vec<PathBuf>, bytes: Vec<u64>) -> CleanRequest {
        CleanRequest { scan_root, selected_paths: paths, selected_bytes: bytes }
    }

    // ── safety guards ────────────────────────────────────────────────────────

    #[test]
    fn blocks_delete_of_scan_root_itself() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        fs::create_dir_all(&root).expect("create root");

        let result = NativeCleaner.clean(&req(root.clone(), vec![root.clone()])).expect("clean");
        assert_eq!(result.removed_count, 0);
        assert!(root.exists());
    }

    #[test]
    fn blocks_delete_outside_root() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let outside = temp.path().join("outside").join("node_modules");
        fs::create_dir_all(&root).expect("create root");
        fs::create_dir_all(&outside).expect("create outside");

        let result = NativeCleaner.clean(&req(root, vec![outside.clone()])).expect("clean");
        assert_eq!(result.removed_count, 0);
        assert!(outside.exists());
    }

    #[test]
    fn blocks_delete_of_file_not_dir() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        fs::create_dir_all(&root).expect("create root");
        let file = root.join("leftover.txt");
        fs::write(&file, b"data").expect("write file");

        let result = NativeCleaner.clean(&req(root, vec![file.clone()])).expect("clean");
        assert_eq!(result.removed_count, 0);
        assert!(file.exists(), "file must not be deleted");
    }

    // ── happy-path deletions ─────────────────────────────────────────────────

    #[test]
    fn deletes_inside_root_and_reports_path() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let target = root.join("project").join("node_modules");
        fs::create_dir_all(&target).expect("create target");
        fs::write(target.join("a.txt"), b"hello").expect("seed file");

        let result = NativeCleaner.clean(&req(root, vec![target.clone()])).expect("clean");
        assert_eq!(result.removed_count, 1);
        assert!(!target.exists());
        assert_eq!(result.removed_paths, vec![target]);
    }

    #[test]
    fn deletes_multiple_sibling_dirs() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let a = root.join("proj-a").join("node_modules");
        let b = root.join("proj-b").join("node_modules");
        fs::create_dir_all(&a).expect("create a");
        fs::create_dir_all(&b).expect("create b");

        let result = NativeCleaner
            .clean(&req(root, vec![a.clone(), b.clone()]))
            .expect("clean");
        assert_eq!(result.removed_count, 2);
        assert!(!a.exists());
        assert!(!b.exists());
        assert_eq!(result.removed_paths.len(), 2);
    }

    #[test]
    fn skips_already_deleted_path_gracefully() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let ghost = root.join("proj").join("node_modules");
        fs::create_dir_all(&root).expect("create root");
        // ghost is NOT created — simulates a path deleted between scan and clean

        let result = NativeCleaner.clean(&req(root, vec![ghost])).expect("clean");
        assert_eq!(result.removed_count, 0);
        assert_eq!(result.removed_bytes, 0);
    }

    #[test]
    fn empty_selection_is_noop() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        fs::create_dir_all(&root).expect("create root");

        let result = NativeCleaner.clean(&req(root, vec![])).expect("clean");
        assert_eq!(result.removed_count, 0);
        assert_eq!(result.removed_bytes, 0);
        assert!(result.removed_paths.is_empty());
    }

    // ── ordering: deepest path deleted first ─────────────────────────────────

    #[test]
    fn parent_and_nested_child_both_selected_delete_cleanly() {
        // child is deeper → deleted first; parent is then removed by remove_dir_all
        // which still succeeds because the parent dir itself still exists.
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let parent = root.join("proj").join("node_modules");
        let child = parent.join("pkg").join("node_modules");
        fs::create_dir_all(&child).expect("create child");

        let result = NativeCleaner
            .clean(&req(root, vec![parent.clone(), child.clone()]))
            .expect("clean");
        assert_eq!(result.removed_count, 2);
        assert!(!parent.exists());
    }

    // ── size-hint optimisation ───────────────────────────────────────────────

    #[test]
    fn uses_known_bytes_without_measuring_again() {
        // If a non-zero hint is provided, removed_bytes must equal the hint —
        // not the real file size (which is different).  This proves the fast
        // path is taken and dir_size is NOT called again.
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let target = root.join("proj").join("node_modules");
        fs::create_dir_all(&target).expect("create target");
        fs::write(target.join("tiny.txt"), b"x").expect("seed");

        const HINT: u64 = 999_888_777;
        let result = NativeCleaner
            .clean(&req_with_bytes(root, vec![target.clone()], vec![HINT]))
            .expect("clean");
        assert_eq!(result.removed_count, 1);
        assert_eq!(result.removed_bytes, HINT);
        assert!(!target.exists());
    }

    #[test]
    fn falls_back_to_dir_size_when_hint_is_zero() {
        // hint = 0 means "unknown" → must measure the real content
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let target = root.join("proj").join("node_modules");
        fs::create_dir_all(&target).expect("create target");
        fs::write(target.join("data.bin"), vec![0u8; 512]).expect("seed 512 bytes");

        let result = NativeCleaner
            .clean(&req_with_bytes(root, vec![target.clone()], vec![0]))
            .expect("clean");
        assert_eq!(result.removed_count, 1);
        assert_eq!(result.removed_bytes, 512);
    }

    // ── mixed selection ──────────────────────────────────────────────────────

    #[test]
    fn mixed_inside_and_outside_only_removes_inside() {
        let temp = tempdir().expect("tempdir");
        let root = temp.path().join("workspace");
        let inside = root.join("proj").join("node_modules");
        let outside = temp.path().join("other").join("node_modules");
        fs::create_dir_all(&inside).expect("create inside");
        fs::create_dir_all(&outside).expect("create outside");

        let result = NativeCleaner
            .clean(&req(root, vec![inside.clone(), outside.clone()]))
            .expect("clean");
        assert_eq!(result.removed_count, 1);
        assert!(!inside.exists());
        assert!(outside.exists());
    }
}
