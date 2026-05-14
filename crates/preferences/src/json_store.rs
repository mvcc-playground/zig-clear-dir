use anyhow::{Context, Result};
use application::LearningStorePort;
use domain::AppLearningState;
use std::fs;
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
        if !self.file.exists() {
            return Ok(AppLearningState::default());
        }
        let data = fs::read_to_string(&self.file).context("failed reading learning file")?;
        let value = serde_json::from_str::<AppLearningState>(&data).context("invalid learning json")?;
        Ok(value)
    }

    fn save(&self, state: &AppLearningState) -> Result<()> {
        if let Some(parent) = self.file.parent() {
            fs::create_dir_all(parent).context("failed creating learning folder")?;
        }
        let content = serde_json::to_string_pretty(state)?;
        fs::write(&self.file, content).context("failed writing learning file")?;
        Ok(())
    }
}
