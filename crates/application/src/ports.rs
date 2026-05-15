use anyhow::Result;
use domain::{AppLearningState, CandidateEntry, CleanRequest, CleanResult, CustomBlockedRoot, ScanRequest, SessionState};
use std::path::PathBuf;

#[derive(Debug, Clone, Copy)]
pub struct ScanProgressSnapshot {
    pub visited_dirs: usize,
    pub matched_dirs: usize,
}

pub trait ScanProgressPort: Send + Sync {
    fn on_progress(&self, snapshot: ScanProgressSnapshot);
    fn is_paused(&self) -> bool {
        false
    }
}

pub trait ScannerPort: Send + Sync {
    fn scan(
        &self,
        request: &ScanRequest,
        learning: &AppLearningState,
        progress: Option<&dyn ScanProgressPort>,
    ) -> Result<Vec<CandidateEntry>>;
}

pub trait CleanerPort: Send + Sync {
    fn clean(&self, request: &CleanRequest) -> Result<CleanResult>;
}

pub trait LearningStorePort: Send + Sync {
    fn load(&self) -> Result<AppLearningState>;
    fn save(&self, state: &AppLearningState) -> Result<()>;
}

/// Persists UI session state across restarts: last root, scan mode,
/// disabled targets, and last selection. Segregated from LearningStorePort
/// so callers (CLI, TUI) that don't need session state don't depend on it.
pub trait SessionStatePort: Send + Sync {
    fn load_session(&self) -> Result<SessionState>;
    fn save_session(&self, state: &SessionState) -> Result<()>;
}

/// Returns the absolute path prefixes that must NEVER be scanned or deleted,
/// regardless of user configuration. Required at CleanerApp construction —
/// any caller that omits this gets a compile error, not a silent miss.
///
/// `user_safe_names` extends the built-in whitelist for platform-specific
/// directories (e.g. AppData\Local on Windows). Pass an empty slice to use
/// only built-in defaults.
///
/// `custom_blocked_roots` are user-defined folders that are blocked entirely,
/// optionally with a per-root whitelist of allowed sub-folder names.
///
/// Implement this for each platform in the platform crate. For testing,
/// use an empty implementation explicitly so the omission is deliberate.
pub trait ProtectedRootsPort: Send + Sync {
    fn protected_roots(
        &self,
        user_safe_names: &[String],
        custom_blocked_roots: &[CustomBlockedRoot],
    ) -> Vec<PathBuf>;
}
