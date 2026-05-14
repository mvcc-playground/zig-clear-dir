use anyhow::Result;
use domain::{AppLearningState, CandidateEntry, CleanRequest, CleanResult, ScanRequest};

pub trait ScannerPort: Send + Sync {
    fn scan(&self, request: &ScanRequest, learning: &AppLearningState) -> Result<Vec<CandidateEntry>>;
}

pub trait CleanerPort: Send + Sync {
    fn clean(&self, request: &CleanRequest) -> Result<CleanResult>;
}

pub trait LearningStorePort: Send + Sync {
    fn load(&self) -> Result<AppLearningState>;
    fn save(&self, state: &AppLearningState) -> Result<()>;
}
