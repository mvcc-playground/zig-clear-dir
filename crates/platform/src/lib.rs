mod fs_backend;
mod system_exclusions;

pub use fs_backend::{NativeCleaner, NativeScanner};
pub use system_exclusions::{is_system_excluded, is_system_protected_name, system_excluded_roots};
