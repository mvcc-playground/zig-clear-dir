use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanRequest {
    pub root: PathBuf,
    pub mode: ScanMode,
    #[serde(default)]
    pub excluded_roots: Vec<PathBuf>,
    #[serde(default)]
    pub active_targets: Vec<String>,
    /// Folder names to skip entirely — any directory whose name matches
    /// is not entered and never appears in results.
    #[serde(default)]
    pub excluded_names: Vec<String>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
pub enum ScanMode {
    Fast,
    #[default]
    Full,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CandidateEntry {
    pub path: PathBuf,
    pub bytes: u64,
    pub kind: String,
    pub selected: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScanResult {
    pub candidates: Vec<CandidateEntry>,
    pub total_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CleanRequest {
    pub scan_root: PathBuf,
    pub selected_paths: Vec<PathBuf>,
    /// Known byte size for each path (parallel to selected_paths).
    /// 0 means unknown — the cleaner will measure with a dir walk.
    /// Passing the scan-time value avoids a redundant tree walk before deletion.
    #[serde(default)]
    pub selected_bytes: Vec<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CleanResult {
    pub removed_count: usize,
    pub removed_bytes: u64,
    pub removed_paths: Vec<PathBuf>,
    /// Paths that could not be deleted and the reason. Non-empty means the
    /// cleaner ran in best-effort mode and some directories survived.
    #[serde(default)]
    pub errors: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LearningStats {
    pub runs: u64,
    pub total_removed_bytes: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct AppLearningState {
    pub favorites: Vec<PathBuf>,
    pub base_targets: Vec<String>,
    pub custom_targets: Vec<String>,
    pub recent_roots: Vec<PathBuf>,
    /// Folder NAMES to skip entirely during scan (e.g. "projeto-web").
    /// Any directory whose name matches is not entered and never appears in results.
    pub excluded_names: Vec<String>,
    /// Extra folder names inside AppData\Local that are safe to scan.
    /// Combined with the built-in whitelist (npm-cache, bun, pub, etc.).
    pub safe_appdata_names: Vec<String>,
    pub stats: LearningStats,
}

impl Default for AppLearningState {
    fn default() -> Self {
        Self {
            favorites: Vec::new(),
            base_targets: Vec::new(),
            custom_targets: Vec::new(),
            recent_roots: Vec::new(),
            excluded_names: Vec::new(),
            safe_appdata_names: Vec::new(),
            stats: LearningStats::default(),
        }
    }
}

/// UI session state persisted across restarts.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SessionState {
    /// Last folder the user scanned.
    pub last_root: Option<PathBuf>,
    /// Last scan mode selected.
    pub last_scan_mode: ScanMode,
    /// Target names the user has unchecked (disabled) in the UI.
    pub disabled_targets: Vec<String>,
    /// Paths that were checked in the last result view.
    pub last_selected_paths: Vec<PathBuf>,
}
