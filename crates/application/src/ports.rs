use anyhow::Result;
use domain::{AppLearningState, CandidateEntry, CleanRequest, CleanResult, ScanRequest};

#[derive(Debug, Clone, Copy)]
pub struct ScanProgressSnapshot {
    pub visited_dirs: usize,
    pub matched_dirs: usize,
}

pub trait ScanProgressPort: Send + Sync {
    fn on_progress(&self, snapshot: ScanProgressSnapshot);
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
