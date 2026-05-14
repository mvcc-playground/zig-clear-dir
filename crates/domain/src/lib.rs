mod models;
mod rules;

pub use models::{
    AppLearningState, CandidateEntry, CleanRequest, CleanResult, LearningStats, ScanMode,
    ScanRequest, ScanResult,
};
pub use rules::{GarbageRules, default_targets_vec};
