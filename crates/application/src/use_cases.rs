use crate::{CleanerPort, LearningStorePort, ProtectedRootsPort, ScanProgressPort, ScannerPort, SessionStatePort};
use anyhow::{Result, bail};
use domain::{
    AppLearningState, CleanRequest, CleanResult, GarbageRules, ScanMode, ScanRequest, ScanResult,
    SessionState, default_targets_vec,
};
use std::path::PathBuf;
use std::sync::Arc;

pub struct CleanerApp {
    scanner: Arc<dyn ScannerPort>,
    cleaner: Arc<dyn CleanerPort>,
    learning_store: Arc<dyn LearningStorePort>,
    session_store: Arc<dyn SessionStatePort>,
    protected_roots: Arc<dyn ProtectedRootsPort>,
}

impl CleanerApp {
    pub fn new(
        scanner: Arc<dyn ScannerPort>,
        cleaner: Arc<dyn CleanerPort>,
        learning_store: Arc<dyn LearningStorePort>,
        session_store: Arc<dyn SessionStatePort>,
        protected_roots: Arc<dyn ProtectedRootsPort>,
    ) -> Self {
        Self { scanner, cleaner, learning_store, session_store, protected_roots }
    }

    pub fn load_learning(&self) -> Result<AppLearningState> {
        self.learning_store.load()
    }

    pub fn load_session(&self) -> Result<SessionState> {
        self.session_store.load_session()
    }

    pub fn save_session(&self, state: &SessionState) -> Result<()> {
        self.session_store.save_session(state)
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

        // Merge caller-supplied exclusions with system-protected roots.
        // This happens here — in the application layer — so no ScannerPort
        // implementation can bypass protection by ignoring excluded_roots.
        let mut merged_exclusions = self.protected_roots.protected_roots(&learning.safe_appdata_names);
        for r in excluded_roots {
            if !merged_exclusions.contains(&r) {
                merged_exclusions.push(r);
            }
        }

        let request = ScanRequest {
            root,
            mode,
            excluded_roots: merged_exclusions,
            active_targets,
            excluded_names: learning.excluded_names.clone(),
        };
        let mut candidates = self.scanner.scan(&request, &learning, progress)?;
        candidates.sort_by(|a, b| b.bytes.cmp(&a.bytes));
        let total_bytes = candidates.iter().map(|v| v.bytes).sum();
        Ok(ScanResult { candidates, total_bytes })
    }

    pub fn clean(&self, request: CleanRequest) -> Result<CleanResult> {
        // Load learning once — used for both the protected-roots check and
        // the stats update, avoiding a double query.
        let mut learning = self.learning_store.load()?;

        // Second line of defense: reject any path inside a protected root
        // before it reaches the cleaner. Guards against bugs where a path
        // entered results without going through the scanner's exclusion check.
        let protected = self.protected_roots.protected_roots(&learning.safe_appdata_names);
        for path in &request.selected_paths {
            if let Some(root) = protected.iter().find(|r| path.starts_with(r)) {
                bail!(
                    "Recusado: '{}' está dentro de '{}', que é uma pasta protegida do sistema. \
                     Remova-a da seleção antes de continuar.",
                    path.display(),
                    root.display()
                );
            }
        }

        let result = self.cleaner.clean(&request)?;
        learning.stats.runs += 1;
        learning.stats.total_removed_bytes += result.removed_bytes;
        self.learning_store.save(&learning)?;
        Ok(result)
    }

    pub fn add_safe_appdata_name(&self, name: String) -> Result<Vec<String>> {
        let mut learning = self.learning_store.load()?;
        let normalized = name.trim().to_ascii_lowercase();
        if !normalized.is_empty()
            && !learning.safe_appdata_names.iter().any(|v| v == &normalized)
        {
            learning.safe_appdata_names.push(normalized);
            learning.safe_appdata_names.sort_unstable();
            learning.safe_appdata_names.dedup();
            self.learning_store.save(&learning)?;
        }
        Ok(learning.safe_appdata_names.clone())
    }

    pub fn remove_safe_appdata_name(&self, name: &str) -> Result<Vec<String>> {
        let mut learning = self.learning_store.load()?;
        let normalized = name.trim().to_ascii_lowercase();
        learning.safe_appdata_names.retain(|v| v != &normalized);
        self.learning_store.save(&learning)?;
        Ok(learning.safe_appdata_names.clone())
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

    pub fn add_excluded_name(&self, name: String) -> Result<Vec<String>> {
        let mut learning = self.learning_store.load()?;
        let normalized = name.trim().to_ascii_lowercase();
        if !normalized.is_empty() && !learning.excluded_names.iter().any(|v| v == &normalized) {
            learning.excluded_names.push(normalized);
            learning.excluded_names.sort_unstable();
            learning.excluded_names.dedup();
            self.learning_store.save(&learning)?;
        }
        Ok(learning.excluded_names.clone())
    }

    pub fn remove_excluded_name(&self, name: &str) -> Result<Vec<String>> {
        let mut learning = self.learning_store.load()?;
        let normalized = name.trim().to_ascii_lowercase();
        learning.excluded_names.retain(|v| v != &normalized);
        self.learning_store.save(&learning)?;
        Ok(learning.excluded_names.clone())
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
    use crate::{CleanerPort, LearningStorePort, ProtectedRootsPort, ScannerPort, SessionStatePort};
    use domain::{CandidateEntry, LearningStats, SessionState};
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
                errors: Vec::new(),
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

    struct MockSessionStore {
        state: Mutex<SessionState>,
    }
    impl SessionStatePort for MockSessionStore {
        fn load_session(&self) -> Result<SessionState> {
            Ok(self.state.lock().expect("lock").clone())
        }
        fn save_session(&self, state: &SessionState) -> Result<()> {
            *self.state.lock().expect("lock") = state.clone();
            Ok(())
        }
    }

    struct MockProtectedRoots(Vec<PathBuf>);
    impl ProtectedRootsPort for MockProtectedRoots {
        fn protected_roots(&self, _user_safe_names: &[String]) -> Vec<PathBuf> {
            self.0.clone()
        }
    }

    fn app_with_state(state: AppLearningState) -> CleanerApp {
        app_with_state_and_roots(state, vec![])
    }

    fn app_with_state_and_roots(state: AppLearningState, protected: Vec<PathBuf>) -> CleanerApp {
        CleanerApp::new(
            Arc::new(MockScanner),
            Arc::new(MockCleaner),
            Arc::new(MockStore { state: Mutex::new(state) }),
            Arc::new(MockSessionStore { state: Mutex::new(SessionState::default()) }),
            Arc::new(MockProtectedRoots(protected)),
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
            excluded_names: Vec::new(),
            safe_appdata_names: Vec::new(),
            stats: LearningStats::default(),
        });
        let _ = app.scan_with_mode(PathBuf::from("C:\\tmp"), ScanMode::Full);
        let learning = app.load_learning().expect("load");
        assert!(!learning.recent_roots.is_empty());
    }

    #[test]
    fn save_and_load_session_roundtrip() {
        let app = app_with_state(AppLearningState::default());
        let session = SessionState {
            last_root: Some(PathBuf::from("C:\\projects")),
            last_scan_mode: ScanMode::Fast,
            disabled_targets: vec!["dist".into()],
            last_selected_paths: vec![PathBuf::from("C:\\projects\\node_modules")],
        };
        app.save_session(&session).expect("save");
        let loaded = app.load_session().expect("load");
        assert_eq!(loaded.last_root, session.last_root);
        assert_eq!(loaded.last_scan_mode, session.last_scan_mode);
        assert_eq!(loaded.disabled_targets, session.disabled_targets);
        assert_eq!(loaded.last_selected_paths, session.last_selected_paths);
    }

    #[test]
    fn add_excluded_name_persists_and_normalizes() {
        let app = app_with_state(AppLearningState::default());
        let list = app.add_excluded_name("Projeto-Web".into()).expect("add");
        assert!(list.iter().any(|v| v == "projeto-web"));
        // idempotent
        let list2 = app.add_excluded_name("projeto-web".into()).expect("add again");
        assert_eq!(list2.iter().filter(|v| *v == "projeto-web").count(), 1);
    }

    #[test]
    fn remove_excluded_name_removes_it() {
        let mut state = AppLearningState::default();
        state.excluded_names = vec!["meu-app".into(), "outro".into()];
        let app = app_with_state(state);
        let list = app.remove_excluded_name("meu-app").expect("remove");
        assert!(!list.iter().any(|v| v == "meu-app"));
        assert!(list.iter().any(|v| v == "outro"));
    }

    #[test]
    fn clean_increments_stats() {
        let app = app_with_state(AppLearningState::default());
        app.clean(CleanRequest {
            scan_root: PathBuf::from("C:\\tmp"),
            selected_paths: Vec::new(),
            selected_bytes: Vec::new(),
        })
        .expect("clean");
        let learning = app.load_learning().expect("load");
        assert_eq!(learning.stats.runs, 1);
    }

    #[test]
    fn clean_rejects_path_inside_protected_root() {
        let protected_root = PathBuf::from("/protected/programs");
        let app = app_with_state_and_roots(
            AppLearningState::default(),
            vec![protected_root.clone()],
        );
        let result = app.clean(CleanRequest {
            scan_root: PathBuf::from("/projects"),
            selected_paths: vec![protected_root.join("cursor").join("node_modules")],
            selected_bytes: Vec::new(),
        });
        assert!(result.is_err());
        let msg = result.unwrap_err().to_string();
        assert!(msg.contains("protegida"), "error should mention protected: {msg}");
    }

    #[test]
    fn clean_allows_path_outside_protected_roots() {
        let protected_root = PathBuf::from("/protected/programs");
        let app = app_with_state_and_roots(
            AppLearningState::default(),
            vec![protected_root],
        );
        let result = app.clean(CleanRequest {
            scan_root: PathBuf::from("/projects"),
            selected_paths: vec![PathBuf::from("/projects/my-app/node_modules")],
            selected_bytes: Vec::new(),
        });
        assert!(result.is_ok());
    }

    #[test]
    fn protected_roots_merged_into_scan_request() {
        // Verifies that CleanerApp injects protected roots into excluded_roots
        // before the scanner sees the request, even when the caller passes none.
        struct CapturingScanner(Mutex<Vec<PathBuf>>);
        impl ScannerPort for CapturingScanner {
            fn scan(
                &self,
                request: &ScanRequest,
                _learning: &AppLearningState,
                _progress: Option<&dyn ScanProgressPort>,
            ) -> Result<Vec<CandidateEntry>> {
                *self.0.lock().unwrap() = request.excluded_roots.clone();
                Ok(Vec::new())
            }
        }

        let protected = vec![PathBuf::from("/sys/protected")];
        let captured = Arc::new(Mutex::new(Vec::<PathBuf>::new()));
        let scanner = Arc::new(CapturingScanner(Mutex::new(Vec::new())));
        let scanner_ref = scanner.clone();

        let app = CleanerApp::new(
            scanner_ref,
            Arc::new(MockCleaner),
            Arc::new(MockStore { state: Mutex::new(AppLearningState::default()) }),
            Arc::new(MockSessionStore { state: Mutex::new(SessionState::default()) }),
            Arc::new(MockProtectedRoots(protected.clone())),
        );

        let _ = app.scan_with_mode(PathBuf::from("/projects"), ScanMode::Fast);
        let captured_roots = scanner.0.lock().unwrap().clone();
        assert!(
            captured_roots.iter().any(|r| r == &protected[0]),
            "scanner must receive protected roots even when caller passes none"
        );
        drop(captured);
    }
}
