use std::path::PathBuf;

/// Returns absolute paths that the scanner must never enter or delete,
/// regardless of user-configured targets. Each entry is a root prefix:
/// any directory whose path starts_with one of these is skipped entirely.
pub fn system_excluded_roots() -> Vec<PathBuf> {
    build_exclusions()
}

#[cfg(windows)]
fn build_exclusions() -> Vec<PathBuf> {
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

    // User-level application installs and tool data under %LOCALAPPDATA%.
    // These directories contain app binaries and managed runtimes — their
    // node_modules / dist / build folders belong to the installed programs,
    // not to user projects, so deleting them would break those programs.
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        let local = PathBuf::from(local);
        // User-installed apps (Cursor, Antigravity, VS Code, etc.)
        roots.push(local.join("Programs"));
        // mise tool manager — manages runtimes (node, python, ruby …)
        roots.push(local.join("mise"));
        // Zed editor data and external agents (Claude Code, Gemini, etc.)
        roots.push(local.join("Zed"));
        // Deno runtime and its npm mirror — managed by deno, not the user
        roots.push(local.join("deno"));
        // Google Chrome / Chromium application data
        roots.push(local.join("Google"));
        // Microsoft Edge application data
        roots.push(local.join("Microsoft").join("Edge"));
    }

    roots
}

#[cfg(target_os = "macos")]
fn build_exclusions() -> Vec<PathBuf> {
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
fn build_exclusions() -> Vec<PathBuf> {
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
fn build_exclusions() -> Vec<PathBuf> {
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
