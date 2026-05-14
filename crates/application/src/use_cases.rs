use crate::{CleanerPort, LearningStorePort, ScanProgressPort, ScannerPort};
use anyhow::Result;
use domain::{
    AppLearningState, CleanRequest, CleanResult, GarbageRules, ScanMode, ScanRequest, ScanResult,
    default_targets_vec,
};
use std::path::PathBuf;
use std::sync::Arc;

pub struct CleanerApp {
    scanner: Arc<dyn ScannerPort>,
    cleaner: Arc<dyn CleanerPort>,
    learning_store: Arc<dyn LearningStorePort>,
}

impl CleanerApp {
    pub fn new(
        scanner: Arc<dyn ScannerPort>,
        cleaner: Arc<dyn CleanerPort>,
        learning_store: Arc<dyn LearningStorePort>,
    ) -> Self {
        Self {
            scanner,
            cleaner,
            learning_store,
        }
    }

    pub fn load_learning(&self) -> Result<AppLearningState> {
        self.learning_store.load()
    }

    pub fn scan_with_mode(&self, root: PathBuf, mode: ScanMode) -> Result<ScanResult> {
        self.scan_with_mode_and_progress(root, mode, None, Vec::new(), Vec::new())
    }

    pub fn scan_with_mode_and_progress(
        &self,
        root: PathBuf,
        mode: ScanMode,
        progress: Option<&dyn ScanProgressPort>,
        excluded_roots: Vec<PathBuf>,
        active_targets: Vec<String>,
    ) -> Result<ScanResult> {
        let mut learning = self.learning_store.load()?;
        if !learning.recent_roots.iter().any(|v| v == &root) {
            learning.recent_roots.insert(0, root.clone());
            learning.recent_roots.truncate(12);
            self.learning_store.save(&learning)?;
        }

        let request = ScanRequest { root, mode, excluded_roots, active_targets };
        let mut candidates = self.scanner.scan(&request, &learning, progress)?;
        candidates.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        let total_bytes = candidates.iter().map(|v| v.bytes).sum();
        Ok(ScanResult {
            candidates,
            total_bytes,
        })
    }

    pub fn clean(&self, request: CleanRequest) -> Result<CleanResult> {
        let result = self.cleaner.clean(&request)?;
        let mut learning = self.learning_store.load()?;
        learning.stats.runs += 1;
        learning.stats.total_removed_bytes += result.removed_bytes;
        self.learning_store.save(&learning)?;
        Ok(result)
    }

    pub fn remove_target(&self, name: &str) -> Result<Vec<String>> {
        let mut learning = self.learning_store.load()?;
        let normalized = name.trim().to_ascii_lowercase();
        learning.base_targets.retain(|t| t != &normalized);
        learning.custom_targets.retain(|t| t != &normalized);
        if learning.base_targets.is_empty() && learning.custom_targets.is_empty() {
            learning.base_targets = default_targets_vec();
        }
        self.learning_store.save(&learning)?;
        let rules = GarbageRules::new(&learning.base_targets, &learning.custom_targets);
        Ok(rules.all_targets())
    }

    pub fn add_custom_target(&self, value: String) -> Result<Vec<String>> {
        let mut learning = self.learning_store.load()?;
        let normalized = value.trim().to_ascii_lowercase();
        if !normalized.is_empty() && !learning.custom_targets.iter().any(|v| v == &normalized) {
            learning.custom_targets.push(normalized);
            learning.custom_targets.sort_unstable();
            learning.custom_targets.dedup();
            self.learning_store.save(&learning)?;
        }
        let rules = GarbageRules::new(&learning.base_targets, &learning.custom_targets);
        Ok(rules.all_targets())
    }

    pub fn set_base_targets_csv(&self, csv: String) -> Result<Vec<String>> {
        let mut learning = self.learning_store.load()?;
        let values = csv
            .split(',')
            .map(|v| v.trim().to_ascii_lowercase())
            .filter(|v| !v.is_empty())
            .collect::<Vec<_>>();
        if values.is_empty() {
            learning.base_targets = default_targets_vec();
        } else {
            learning.base_targets = values;
            learning.base_targets.sort_unstable();
            learning.base_targets.dedup();
        }
        self.learning_store.save(&learning)?;
        let rules = GarbageRules::new(&learning.base_targets, &learning.custom_targets);
        Ok(rules.all_targets())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{CleanerPort, LearningStorePort, ScannerPort};
    use domain::{CandidateEntry, LearningStats};
    use std::path::PathBuf;
    use std::sync::Mutex;

    struct MockScanner;
    impl ScannerPort for MockScanner {
        fn scan(
            &self,
            _request: &ScanRequest,
            _learning: &AppLearningState,
            _progress: Option<&dyn ScanProgressPort>,
        ) -> Result<Vec<CandidateEntry>> {
            Ok(Vec::new())
        }
    }

    struct MockCleaner;
    impl CleanerPort for MockCleaner {
        fn clean(&self, _request: &CleanRequest) -> Result<CleanResult> {
            Ok(CleanResult {
                removed_count: 0,
                removed_bytes: 0,
                removed_paths: Vec::new(),
            })
        }
    }

    struct MockStore {
        state: Mutex<AppLearningState>,
    }
    impl LearningStorePort for MockStore {
        fn load(&self) -> Result<AppLearningState> {
            Ok(self.state.lock().expect("lock").clone())
        }
        fn save(&self, state: &AppLearningState) -> Result<()> {
            *self.state.lock().expect("lock") = state.clone();
            Ok(())
        }
    }

    fn app_with_state(state: AppLearningState) -> CleanerApp {
        CleanerApp::new(
            Arc::new(MockScanner),
            Arc::new(MockCleaner),
            Arc::new(MockStore {
                state: Mutex::new(state),
            }),
        )
    }

    #[test]
    fn set_base_targets_csv_normalizes_and_dedups() {
        let app = app_with_state(AppLearningState::default());
        let targets = app
            .set_base_targets_csv("Node_Modules,dist,dist,.NEXT".into())
            .expect("set base");
        assert!(targets.iter().any(|v| v == "node_modules"));
        assert!(targets.iter().any(|v| v == "dist"));
        assert!(targets.iter().any(|v| v == ".next"));
    }

    #[test]
    fn empty_base_targets_csv_restores_defaults() {
        let mut state = AppLearningState::default();
        state.base_targets = vec!["only-this".into()];
        let app = app_with_state(state);
        let targets = app.set_base_targets_csv("".into()).expect("reset base");
        assert!(targets.iter().any(|v| v == "node_modules"));
    }

    #[test]
    fn scan_registers_recent_root() {
        let app = app_with_state(AppLearningState {
            favorites: Vec::new(),
            base_targets: Vec::new(),
            custom_targets: Vec::new(),
            recent_roots: Vec::new(),
            stats: LearningStats::default(),
        });
        let _ = app.scan_with_mode(PathBuf::from("C:\\tmp"), ScanMode::Full);
        let learning = app.load_learning().expect("load");
        assert!(!learning.recent_roots.is_empty());
    }
}
