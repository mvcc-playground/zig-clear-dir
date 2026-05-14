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
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum ScanMode {
    Fast,
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
    pub stats: LearningStats,
}

impl Default for AppLearningState {
    fn default() -> Self {
        Self {
            favorites: Vec::new(),
            base_targets: Vec::new(),
            custom_targets: Vec::new(),
            recent_roots: Vec::new(),
            stats: LearningStats::default(),
        }
    }
}
