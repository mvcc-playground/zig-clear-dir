use anyhow::{Context, Result};
use application::LearningStorePort;
use domain::AppLearningState;
use std::fs;
use std::io;
use std::path::PathBuf;

pub struct JsonLearningStore {
    file: PathBuf,
}

impl JsonLearningStore {
    pub fn new() -> Self {
        let mut base = dirs::data_local_dir().unwrap_or_else(std::env::temp_dir);
        base.push("clear-dev-cache");
        let mut file = base.clone();
        file.push("learning.json");
        Self { file }
    }
}

impl LearningStorePort for JsonLearningStore {
    fn load(&self) -> Result<AppLearningState> {
        // Use the NotFound error instead of a prior exists() check to avoid a
        // TOCTOU race where the file is deleted between the check and the open.
        match fs::read_to_string(&self.file) {
            Ok(data) => serde_json::from_str::<AppLearningState>(&data)
                .context("invalid learning json"),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(AppLearningState::default()),
            Err(e) => Err(e).context("failed reading learning file"),
        }
    }

    fn save(&self, state: &AppLearningState) -> Result<()> {
        if let Some(parent) = self.file.parent() {
            fs::create_dir_all(parent).context("failed creating learning folder")?;
        }
        let content = serde_json::to_string_pretty(state)?;
        // Write to a sibling .tmp file first, then rename into place.
        // fs::rename is atomic on the same volume on all supported platforms,
        // so a crash mid-write cannot leave a half-written or empty JSON file.
        let tmp = self.file.with_extension("tmp");
        fs::write(&tmp, &content).context("failed writing temp learning file")?;
        fs::rename(&tmp, &self.file).context("failed committing learning file")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use domain::AppLearningState;
    use tempfile::tempdir;

    fn store_in(dir: &std::path::Path) -> JsonLearningStore {
        JsonLearningStore { file: dir.join("learning.json") }
    }

    // ── load ─────────────────────────────────────────────────────────────────

    #[test]
    fn load_returns_default_when_file_missing() {
        let temp = tempdir().expect("tempdir");
        let store = store_in(temp.path());
        // File does not exist — must return default without error (not TOCTOU panic)
        let state = store.load().expect("load");
        assert!(state.base_targets.is_empty());
        assert!(state.recent_roots.is_empty());
    }

    #[test]
    fn load_returns_err_on_corrupt_json() {
        let temp = tempdir().expect("tempdir");
        let store = store_in(temp.path());
        fs::write(&store.file, b"}{not valid json").expect("write");
        let result = store.load();
        assert!(result.is_err());
        let msg = format!("{:?}", result.unwrap_err());
        assert!(msg.contains("invalid learning json"));
    }

    // ── save + roundtrip ─────────────────────────────────────────────────────

    #[test]
    fn save_and_load_roundtrip() {
        let temp = tempdir().expect("tempdir");
        let store = store_in(temp.path());
        let mut state = AppLearningState::default();
        state.base_targets = vec!["my-cache".into(), "dist".into()];
        store.save(&state).expect("save");

        let loaded = store.load().expect("load");
        assert_eq!(loaded.base_targets, vec!["my-cache", "dist"]);
    }

    #[test]
    fn save_creates_parent_directories() {
        let temp = tempdir().expect("tempdir");
        // Nest the file two levels deep — neither level exists yet
        let store = JsonLearningStore {
            file: temp.path().join("a").join("b").join("learning.json"),
        };
        store.save(&AppLearningState::default()).expect("save");
        assert!(store.file.exists());
    }

    // ── atomicity ────────────────────────────────────────────────────────────

    #[test]
    fn save_leaves_no_tmp_file_on_success() {
        let temp = tempdir().expect("tempdir");
        let store = store_in(temp.path());
        store.save(&AppLearningState::default()).expect("save");

        let tmp = store.file.with_extension("tmp");
        assert!(
            !tmp.exists(),
            ".tmp must be renamed away after a successful save"
        );
    }

    #[test]
    fn second_save_overwrites_first() {
        let temp = tempdir().expect("tempdir");
        let store = store_in(temp.path());

        let mut s1 = AppLearningState::default();
        s1.base_targets = vec!["first".into()];
        store.save(&s1).expect("save 1");

        let mut s2 = AppLearningState::default();
        s2.base_targets = vec!["second".into()];
        store.save(&s2).expect("save 2");

        let loaded = store.load().expect("load");
        assert_eq!(loaded.base_targets, vec!["second"]);
    }
}
