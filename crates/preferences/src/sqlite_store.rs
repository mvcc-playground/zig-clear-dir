use anyhow::{Context, Result};
use application::{LearningStorePort, SessionStatePort};
use domain::{AppLearningState, LearningStats, ScanMode, SessionState, default_targets_vec};
use rusqlite::{Connection, params};
use std::path::Path;
use std::sync::Mutex;

// ─── Schema ──────────────────────────────────────────────────────────────────

const SCHEMA_V1: &str = "
    PRAGMA journal_mode = WAL;
    PRAGMA synchronous  = NORMAL;

    CREATE TABLE IF NOT EXISTS schema_version (
        version    INTEGER PRIMARY KEY,
        applied_at INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS kv (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS scan_roots (
        path      TEXT    PRIMARY KEY,
        last_used INTEGER NOT NULL
    );

    CREATE TABLE IF NOT EXISTS targets (
        name TEXT PRIMARY KEY,
        kind TEXT NOT NULL CHECK(kind IN ('base','custom'))
    );

    CREATE TABLE IF NOT EXISTS excluded_names (
        name TEXT PRIMARY KEY
    );

    CREATE TABLE IF NOT EXISTS last_selection (
        path TEXT PRIMARY KEY
    );
";

// ─── Store ───────────────────────────────────────────────────────────────────

/// SQLite-backed implementation of both [`LearningStorePort`] and
/// [`SessionStatePort`]. Use a single `Arc<SqliteStore>` and clone it where
/// each port is expected — both traits are satisfied by the same struct.
///
/// The database is created under the OS data-local directory at
/// `clear-dev-cache/state.db`. For tests, use [`SqliteStore::open`] with a
/// [`tempfile`] path.
pub struct SqliteStore {
    conn: Mutex<Connection>,
}

impl SqliteStore {
    /// Opens (or creates) the database at the default OS path.
    pub fn new() -> Result<Self> {
        let mut dir = dirs::data_local_dir().unwrap_or_else(std::env::temp_dir);
        dir.push("clear-dev-cache");
        std::fs::create_dir_all(&dir).context("failed creating data dir")?;
        Self::open(&dir.join("state.db"))
    }

    /// Opens (or creates) the database at `path`. Useful for tests.
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path).context("failed opening sqlite db")?;
        conn.execute_batch(SCHEMA_V1).context("failed initializing schema")?;
        Ok(Self { conn: Mutex::new(conn) })
    }
}

// ─── LearningStorePort ───────────────────────────────────────────────────────

impl LearningStorePort for SqliteStore {
    fn load(&self) -> Result<AppLearningState> {
        let conn = self.conn.lock().expect("sqlite mutex");

        let runs = kv_get_u64(&conn, "stats.runs")?.unwrap_or(0);
        let total_removed_bytes = kv_get_u64(&conn, "stats.total_removed_bytes")?.unwrap_or(0);

        let recent_roots = {
            let mut stmt = conn.prepare(
                "SELECT path FROM scan_roots ORDER BY last_used DESC LIMIT 12",
            )?;
            stmt.query_map([], |row| row.get::<_, String>(0))?
                .filter_map(Result::ok)
                .map(std::path::PathBuf::from)
                .collect()
        };

        let base_targets: Vec<String> = {
            let mut stmt =
                conn.prepare("SELECT name FROM targets WHERE kind='base' ORDER BY name")?;
            stmt.query_map([], |row| row.get(0))?
                .filter_map(Result::ok)
                .collect()
        };

        let custom_targets: Vec<String> = {
            let mut stmt =
                conn.prepare("SELECT name FROM targets WHERE kind='custom' ORDER BY name")?;
            stmt.query_map([], |row| row.get(0))?
                .filter_map(Result::ok)
                .collect()
        };

        let excluded_names: Vec<String> = {
            let mut stmt = conn.prepare("SELECT name FROM excluded_names ORDER BY name")?;
            stmt.query_map([], |row| row.get(0))?
                .filter_map(Result::ok)
                .collect()
        };

        // First run — no targets in DB yet, return built-in defaults.
        let base_targets = if base_targets.is_empty() && custom_targets.is_empty() {
            default_targets_vec()
        } else {
            base_targets
        };

        Ok(AppLearningState {
            favorites: Vec::new(),
            base_targets,
            custom_targets,
            recent_roots,
            excluded_names,
            stats: LearningStats { runs, total_removed_bytes },
        })
    }

    fn save(&self, state: &AppLearningState) -> Result<()> {
        let mut conn = self.conn.lock().expect("sqlite mutex");
        let tx = conn.transaction()?;

        kv_set(&tx, "stats.runs", &state.stats.runs.to_string())?;
        kv_set(&tx, "stats.total_removed_bytes", &state.stats.total_removed_bytes.to_string())?;

        // Rebuild scan_roots preserving insertion order as recency rank.
        tx.execute("DELETE FROM scan_roots", [])?;
        let now = now_ms();
        for (i, root) in state.recent_roots.iter().enumerate() {
            tx.execute(
                "INSERT OR REPLACE INTO scan_roots (path, last_used) VALUES (?1, ?2)",
                params![root.to_string_lossy().as_ref(), now - i as i64],
            )?;
        }

        // Rebuild targets.
        tx.execute("DELETE FROM targets", [])?;
        for name in &state.base_targets {
            tx.execute(
                "INSERT INTO targets (name, kind) VALUES (?1, 'base')",
                params![name],
            )?;
        }
        for name in &state.custom_targets {
            tx.execute(
                "INSERT INTO targets (name, kind) VALUES (?1, 'custom')",
                params![name],
            )?;
        }

        // Rebuild excluded names.
        tx.execute("DELETE FROM excluded_names", [])?;
        for name in &state.excluded_names {
            tx.execute("INSERT INTO excluded_names (name) VALUES (?1)", params![name])?;
        }

        tx.commit()?;
        Ok(())
    }
}

// ─── SessionStatePort ────────────────────────────────────────────────────────

impl SessionStatePort for SqliteStore {
    fn load_session(&self) -> Result<SessionState> {
        let conn = self.conn.lock().expect("sqlite mutex");

        let last_root = kv_get_str(&conn, "session.last_root")?
            .map(std::path::PathBuf::from);

        let last_scan_mode = kv_get_str(&conn, "session.scan_mode")?
            .and_then(|s| match s.as_str() {
                "fast" => Some(ScanMode::Fast),
                "full" => Some(ScanMode::Full),
                _ => None,
            })
            .unwrap_or_default();

        let disabled_targets: Vec<String> =
            kv_get_str(&conn, "session.disabled_targets")?
                .map(|s| {
                    s.split(',')
                        .filter(|v| !v.is_empty())
                        .map(str::to_string)
                        .collect()
                })
                .unwrap_or_default();

        let last_selected_paths = {
            let mut stmt = conn.prepare("SELECT path FROM last_selection")?;
            stmt.query_map([], |row| row.get::<_, String>(0))?
                .filter_map(Result::ok)
                .map(std::path::PathBuf::from)
                .collect()
        };

        Ok(SessionState { last_root, last_scan_mode, disabled_targets, last_selected_paths })
    }

    fn save_session(&self, state: &SessionState) -> Result<()> {
        let mut conn = self.conn.lock().expect("sqlite mutex");
        let tx = conn.transaction()?;

        match &state.last_root {
            Some(p) => kv_set(&tx, "session.last_root", &p.to_string_lossy())?,
            None => {
                tx.execute("DELETE FROM kv WHERE key='session.last_root'", [])?;
            }
        }

        kv_set(
            &tx,
            "session.scan_mode",
            match state.last_scan_mode {
                ScanMode::Fast => "fast",
                ScanMode::Full => "full",
            },
        )?;

        kv_set(&tx, "session.disabled_targets", &state.disabled_targets.join(","))?;

        tx.execute("DELETE FROM last_selection", [])?;
        for path in &state.last_selected_paths {
            tx.execute(
                "INSERT OR IGNORE INTO last_selection (path) VALUES (?1)",
                params![path.to_string_lossy().as_ref()],
            )?;
        }

        tx.commit()?;
        Ok(())
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn kv_get_str(conn: &Connection, key: &str) -> Result<Option<String>> {
    let mut stmt = conn.prepare_cached("SELECT value FROM kv WHERE key=?1")?;
    let mut rows = stmt.query(params![key])?;
    Ok(rows.next()?.map(|r| r.get(0)).transpose()?)
}

fn kv_get_u64(conn: &Connection, key: &str) -> Result<Option<u64>> {
    Ok(kv_get_str(conn, key)?.and_then(|s| s.parse().ok()))
}

fn kv_set(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO kv (key, value) VALUES (?1, ?2)",
        params![key, value],
    )?;
    Ok(())
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as i64
}

// ─── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use domain::{AppLearningState, LearningStats, ScanMode, SessionState};
    use std::path::PathBuf;
    use tempfile::tempdir;

    fn store_in(dir: &Path) -> SqliteStore {
        SqliteStore::open(&dir.join("test.db")).expect("open")
    }

    // ── LearningStorePort ─────────────────────────────────────────────────

    #[test]
    fn load_returns_defaults_on_empty_db() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());
        let state = store.load().expect("load");
        // base_targets falls back to built-in defaults when the DB is empty
        assert!(!state.base_targets.is_empty());
        assert!(state.base_targets.iter().any(|t| t == "node_modules"));
        assert!(state.recent_roots.is_empty());
        assert_eq!(state.stats.runs, 0);
    }

    #[test]
    fn learning_roundtrip() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let mut state = AppLearningState::default();
        state.base_targets = vec!["dist".into(), "node_modules".into()];
        state.custom_targets = vec!["my-cache".into()];
        state.recent_roots = vec![PathBuf::from("/home/user/proj")];
        state.stats = LearningStats { runs: 5, total_removed_bytes: 1024 };

        store.save(&state).expect("save");
        let loaded = store.load().expect("load");

        assert_eq!(loaded.base_targets, state.base_targets);
        assert_eq!(loaded.custom_targets, state.custom_targets);
        assert_eq!(loaded.recent_roots, state.recent_roots);
        assert_eq!(loaded.stats.runs, 5);
        assert_eq!(loaded.stats.total_removed_bytes, 1024);
    }

    #[test]
    fn second_save_overwrites_targets() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let mut s1 = AppLearningState::default();
        s1.base_targets = vec!["first".into()];
        store.save(&s1).expect("save 1");

        let mut s2 = AppLearningState::default();
        s2.base_targets = vec!["second".into()];
        store.save(&s2).expect("save 2");

        let loaded = store.load().expect("load");
        assert_eq!(loaded.base_targets, vec!["second"]);
    }

    #[test]
    fn recent_roots_capped_at_12() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let mut state = AppLearningState::default();
        state.base_targets = default_targets_vec();
        state.recent_roots = (0..15)
            .map(|i| PathBuf::from(format!("/path/{i}")))
            .collect();
        store.save(&state).expect("save");

        let loaded = store.load().expect("load");
        assert_eq!(loaded.recent_roots.len(), 12);
    }

    #[test]
    fn stats_accumulate_across_saves() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let mut state = AppLearningState::default();
        state.base_targets = default_targets_vec();
        state.stats = LearningStats { runs: 3, total_removed_bytes: 500 };
        store.save(&state).expect("first save");

        state.stats.runs = 7;
        state.stats.total_removed_bytes = 9000;
        store.save(&state).expect("second save");

        let loaded = store.load().expect("load");
        assert_eq!(loaded.stats.runs, 7);
        assert_eq!(loaded.stats.total_removed_bytes, 9000);
    }

    // ── SessionStatePort ──────────────────────────────────────────────────

    #[test]
    fn session_roundtrip() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let session = SessionState {
            last_root: Some(PathBuf::from("/home/user/work")),
            last_scan_mode: ScanMode::Fast,
            disabled_targets: vec!["dist".into(), ".next".into()],
            last_selected_paths: vec![
                PathBuf::from("/home/user/work/node_modules"),
                PathBuf::from("/home/user/work/.cache"),
            ],
        };
        store.save_session(&session).expect("save");
        let loaded = store.load_session().expect("load");

        assert_eq!(loaded.last_root, session.last_root);
        assert_eq!(loaded.last_scan_mode, ScanMode::Fast);
        assert_eq!(loaded.disabled_targets, session.disabled_targets);
        assert_eq!(loaded.last_selected_paths.len(), 2);
    }

    #[test]
    fn session_defaults_when_empty() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());
        let loaded = store.load_session().expect("load");
        assert!(loaded.last_root.is_none());
        assert_eq!(loaded.last_scan_mode, ScanMode::Full);
        assert!(loaded.disabled_targets.is_empty());
        assert!(loaded.last_selected_paths.is_empty());
    }

    #[test]
    fn session_clears_last_root_when_none() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let with_root = SessionState {
            last_root: Some(PathBuf::from("/some/path")),
            ..Default::default()
        };
        store.save_session(&with_root).expect("save with root");

        let without_root = SessionState { last_root: None, ..Default::default() };
        store.save_session(&without_root).expect("save without root");

        let loaded = store.load_session().expect("load");
        assert!(loaded.last_root.is_none());
    }

    #[test]
    fn selection_replaced_on_each_save() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let first = SessionState {
            last_selected_paths: vec![PathBuf::from("/a"), PathBuf::from("/b")],
            ..Default::default()
        };
        store.save_session(&first).expect("first save");

        let second = SessionState {
            last_selected_paths: vec![PathBuf::from("/c")],
            ..Default::default()
        };
        store.save_session(&second).expect("second save");

        let loaded = store.load_session().expect("load");
        assert_eq!(loaded.last_selected_paths, vec![PathBuf::from("/c")]);
    }

    #[test]
    fn excluded_names_roundtrip() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let mut state = AppLearningState::default();
        state.base_targets = default_targets_vec();
        state.excluded_names = vec!["projeto-web".into(), "cliente-ativo".into()];
        store.save(&state).expect("save");

        let loaded = store.load().expect("load");
        assert_eq!(loaded.excluded_names, vec!["cliente-ativo", "projeto-web"]);
    }

    #[test]
    fn excluded_names_cleared_on_empty_save() {
        let dir = tempdir().unwrap();
        let store = store_in(dir.path());

        let mut state = AppLearningState::default();
        state.base_targets = default_targets_vec();
        state.excluded_names = vec!["meu-app".into()];
        store.save(&state).expect("first save");

        state.excluded_names.clear();
        store.save(&state).expect("second save");

        let loaded = store.load().expect("load");
        assert!(loaded.excluded_names.is_empty());
    }

    #[test]
    fn two_stores_same_db_share_state() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("shared.db");

        let writer = SqliteStore::open(&path).expect("writer");
        let mut state = AppLearningState::default();
        state.base_targets = vec!["node_modules".into()];
        writer.save(&state).expect("save");
        drop(writer);

        let reader = SqliteStore::open(&path).expect("reader");
        let loaded = reader.load().expect("load");
        assert_eq!(loaded.base_targets, vec!["node_modules"]);
    }
}
