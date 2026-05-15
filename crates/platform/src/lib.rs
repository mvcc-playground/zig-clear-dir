mod fs_backend;
mod system_exclusions;

pub use fs_backend::{NativeCleaner, NativeScanner};
pub use system_exclusions::{is_system_excluded, is_system_protected_name, system_excluded_roots};

use application::ProtectedRootsPort;
use std::path::PathBuf;

/// Platform implementation of [`ProtectedRootsPort`].
/// Returns OS-specific paths that must never be scanned or cleaned.
pub struct NativeProtectedRoots;

impl ProtectedRootsPort for NativeProtectedRoots {
    fn protected_roots(&self) -> Vec<PathBuf> {
        system_excluded_roots()
    }
}
