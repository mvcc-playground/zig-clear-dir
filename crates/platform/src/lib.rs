mod fs_backend;
mod system_exclusions;

pub use fs_backend::{NativeCleaner, NativeScanner};
pub use system_exclusions::{
    SAFE_APPDATA_LOCAL, appdata_excluded_roots, is_system_excluded, is_system_protected_name,
    system_excluded_roots,
};

use application::ProtectedRootsPort;
use std::path::PathBuf;

/// Platform implementation of [`ProtectedRootsPort`].
///
/// Combines two lists:
/// - OS system roots (Windows, Program Files, /System, etc.)
/// - AppData whitelist: ALL of AppData\Local is blocked except the folders
///   listed in [`system_exclusions::SAFE_APPDATA_LOCAL`]. Any unknown tool
///   installed under AppData\Local is protected by default.
pub struct NativeProtectedRoots;

impl ProtectedRootsPort for NativeProtectedRoots {
    fn protected_roots(&self, user_safe_names: &[String]) -> Vec<PathBuf> {
        let mut roots = system_excluded_roots();
        roots.extend(appdata_excluded_roots(user_safe_names));
        roots
    }
}
