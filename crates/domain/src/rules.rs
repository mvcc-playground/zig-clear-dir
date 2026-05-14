use std::collections::HashSet;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct GarbageRules {
    targets: HashSet<String>,
}

impl GarbageRules {
    pub fn new(base_targets: &[String], extra_targets: &[String]) -> Self {
        let mut targets = if base_targets.is_empty() {
            default_targets()
                .into_iter()
                .map(normalize)
                .collect::<HashSet<_>>()
        } else {
            base_targets.iter().map(|v| normalize(v)).collect::<HashSet<_>>()
        };
        for t in extra_targets {
            targets.insert(normalize(t));
        }
        Self { targets }
    }

    pub fn matches_dir_name(&self, path: &Path) -> Option<String> {
        let name = path.file_name()?.to_string_lossy().to_string();
        let normalized = normalize(&name);
        if self.targets.contains(&normalized) {
            Some(name)
        } else {
            None
        }
    }

    pub fn all_targets(&self) -> Vec<String> {
        let mut out = self.targets.iter().cloned().collect::<Vec<_>>();
        out.sort_unstable();
        out
    }
}

fn normalize(v: &str) -> String {
    v.trim().to_ascii_lowercase()
}

fn default_targets() -> Vec<&'static str> {
    vec![
        "node_modules",
        "target",
        "dist",
        "build",
        ".next",
        ".nuxt",
        ".svelte-kit",
        "__pycache__",
        ".pytest_cache",
        ".cache",
        ".gradle",
        ".turbo",
        ".parcel-cache",
    ]
}

pub fn default_targets_vec() -> Vec<String> {
    default_targets()
        .into_iter()
        .map(|v| v.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn uses_default_targets_when_base_is_empty() {
        let rules = GarbageRules::new(&[], &[]);
        assert!(rules.matches_dir_name(Path::new("node_modules")).is_some());
    }

    #[test]
    fn uses_base_targets_when_provided() {
        let rules = GarbageRules::new(&["cachex".into()], &[]);
        assert!(rules.matches_dir_name(Path::new("cachex")).is_some());
        assert!(rules.matches_dir_name(Path::new("node_modules")).is_none());
    }

    #[test]
    fn merges_custom_targets() {
        let rules = GarbageRules::new(&["cachex".into()], &["custom-trash".into()]);
        assert!(rules.matches_dir_name(Path::new("custom-trash")).is_some());
    }
}
