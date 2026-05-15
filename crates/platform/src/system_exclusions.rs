use std::path::PathBuf;

/// Returns absolute paths that the scanner must never enter or delete,
/// regardless of user-configured targets. Each entry is a root prefix:
/// any directory whose path starts_with one of these is skipped entirely.
///
/// Does NOT include AppData — use [`appdata_excluded_roots`] for that.
pub fn system_excluded_roots() -> Vec<PathBuf> {
    build_os_roots()
}

/// Returns blocked roots derived from AppData using a whitelist strategy:
/// ALL subdirectories of AppData\Local are blocked EXCEPT the ones in
/// [`SAFE_APPDATA_LOCAL`]. AppData\Roaming is blocked entirely.
///
/// This is safer than a blacklist — any unknown tool installed under
/// AppData\Local is protected by default without manual updates.
pub fn appdata_excluded_roots() -> Vec<PathBuf> {
    build_appdata_roots()
}

/// AppData\Local subdirectories that are safe to scan.
/// Everything else under AppData\Local is treated as protected by default.
pub const SAFE_APPDATA_LOCAL: &[&str] = &[
    "npm-cache", // npm global cache
    "bun",       // bun package manager
    "pub",       // Dart / Flutter pub cache
    "pnpm",      // pnpm content-addressable store
    "yarn",      // yarn cache
    "pip",       // Python pip cache (rare on Windows but safe)
    "uv",        // Python uv package manager
    "cargo",     // Rust cargo registry cache
    "pyenv",     // pyenv version manager
];

#[cfg(windows)]
fn build_os_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();

    // %SYSTEMROOT% → C:\Windows
    if let Ok(v) = std::env::var("SYSTEMROOT") {
        roots.push(PathBuf::from(v));
    }
    // %WINDIR% fallback for older setups
    if let Ok(v) = std::env::var("WINDIR") {
        let p = PathBuf::from(v);
        if !roots.contains(&p) {
            roots.push(p);
        }
    }
    // %PROGRAMFILES% → C:\Program Files
    if let Ok(v) = std::env::var("PROGRAMFILES") {
        roots.push(PathBuf::from(v));
    }
    // %PROGRAMFILES(X86)% → C:\Program Files (x86)
    if let Ok(v) = std::env::var("PROGRAMFILES(X86)") {
        roots.push(PathBuf::from(v));
    }

    roots
}

#[cfg(windows)]
fn build_appdata_roots() -> Vec<PathBuf> {
    let mut blocked = Vec::new();

    // AppData\Roaming — app config and state, never project artifacts.
    if let Ok(v) = std::env::var("APPDATA") {
        blocked.push(PathBuf::from(v));
    }

    // AppData\Local — whitelist approach: enumerate children and block
    // everything that is NOT in SAFE_APPDATA_LOCAL.
    if let Ok(local_str) = std::env::var("LOCALAPPDATA") {
        let local = PathBuf::from(&local_str);
        match std::fs::read_dir(&local) {
            Ok(entries) => {
                for entry in entries.flatten() {
                    if entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                        let raw = entry.file_name();
                        let name = raw.to_string_lossy().to_ascii_lowercase();
                        let safe = SAFE_APPDATA_LOCAL
                            .iter()
                            .any(|s| s.eq_ignore_ascii_case(&name));
                        if !safe {
                            blocked.push(entry.path());
                        }
                    }
                }
            }
            // If we cannot read AppData\Local at all, block the whole dir.
            Err(_) => blocked.push(local),
        }
    }

    blocked
}

#[cfg(target_os = "macos")]
fn build_os_roots() -> Vec<PathBuf> {
    let mut roots = vec![
        PathBuf::from("/System"),
        PathBuf::from("/Library"),
        PathBuf::from("/private"),
        PathBuf::from("/usr"),
        PathBuf::from("/bin"),
        PathBuf::from("/sbin"),
        PathBuf::from("/etc"),
        PathBuf::from("/var"),
        PathBuf::from("/dev"),
        PathBuf::from("/cores"),
        PathBuf::from("/Volumes"),
    ];
    if let Some(home) = dirs::home_dir() {
        roots.push(home.join(".Trash"));
        roots.push(home.join("Library"));
    }
    roots
}

#[cfg(target_os = "linux")]
fn build_os_roots() -> Vec<PathBuf> {
    vec![
        PathBuf::from("/proc"),
        PathBuf::from("/sys"),
        PathBuf::from("/dev"),
        PathBuf::from("/run"),
        PathBuf::from("/boot"),
        PathBuf::from("/bin"),
        PathBuf::from("/sbin"),
        PathBuf::from("/usr/bin"),
        PathBuf::from("/usr/sbin"),
        PathBuf::from("/usr/lib"),
        PathBuf::from("/usr/lib64"),
        PathBuf::from("/etc"),
        PathBuf::from("/lib"),
        PathBuf::from("/lib64"),
        PathBuf::from("/snap"),
    ]
}

#[cfg(not(any(windows, target_os = "macos", target_os = "linux")))]
fn build_os_roots() -> Vec<PathBuf> {
    Vec::new()
}

// AppData is a Windows concept — no-op on other platforms.
#[cfg(not(windows))]
fn build_appdata_roots() -> Vec<PathBuf> {
    Vec::new()
}

/// Returns true if `path` starts with any of the excluded roots.
pub fn is_system_excluded(path: &std::path::Path, excluded: &[PathBuf]) -> bool {
    excluded.iter().any(|root| path.starts_with(root))
}

/// Additionally blocks bare directory names that are OS-protected at any depth.
/// Used for folder names that appear on any drive regardless of absolute path.
pub fn is_system_protected_name(name: &str) -> bool {
    #[cfg(windows)]
    {
        matches!(
            name.to_ascii_lowercase().as_str(),
            "$recycle.bin" | "system volume information" | "recovery" | "windowsapps" | "programdata"
        )
    }
    #[cfg(not(windows))]
    {
        let _ = name;
        false
    }
}
