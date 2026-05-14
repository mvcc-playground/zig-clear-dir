use anyhow::Result;
use application::{CleanerApp, ScanProgressPort, ScanProgressSnapshot};
use domain::{CleanRequest, CleanResult, ScanMode, ScanResult, default_targets_vec};
use eframe::egui::{self, Align, Color32, Layout, RichText};
use platform::{NativeCleaner, NativeScanner, system_excluded_roots};
use preferences::JsonLearningStore;
use rfd::{FileDialog, MessageButtons, MessageDialog, MessageDialogResult, MessageLevel};
use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::time::{Duration, Instant};

fn main() -> Result<()> {
    let scanner = Arc::new(NativeScanner);
    let cleaner = Arc::new(NativeCleaner);
    let learning = Arc::new(JsonLearningStore::new());
    let app = Arc::new(CleanerApp::new(scanner, cleaner, learning));

    let mut native_options = eframe::NativeOptions::default();
    native_options.viewport = egui::ViewportBuilder::default()
        .with_inner_size([820.0, 600.0])
        .with_min_inner_size([640.0, 480.0]);

    eframe::run_native(
        "Clear Dev Cache",
        native_options,
        Box::new(|_cc| Ok(Box::new(DesktopCleanerUi::new(app)))),
    )
    .map_err(|e| anyhow::anyhow!("eframe error: {e}"))?;

    Ok(())
}

// ─── Domain types ────────────────────────────────────────────────────────────

#[derive(Clone)]
struct RowState {
    path: PathBuf,
    kind: String,
    bytes: u64,
    has_exact_size: bool,
    selected: bool,
}

#[derive(Clone)]
struct TargetEntry {
    name: String,
    is_custom: bool,
    enabled: bool,
}

#[derive(PartialEq, Clone, Copy, Default)]
enum SortColumn {
    Kind,
    Path,
    #[default]
    Size,
}

enum Step {
    Configure,
    Scanning,
    Review,
}

// ─── Speed tracker ───────────────────────────────────────────────────────────

struct SpeedTracker {
    last_visited: usize,
    last_time: Instant,
    speed_dirs_per_sec: f32,
}

impl SpeedTracker {
    fn new() -> Self {
        Self { last_visited: 0, last_time: Instant::now(), speed_dirs_per_sec: 0.0 }
    }

    fn update(&mut self, visited: usize) {
        let elapsed = self.last_time.elapsed().as_secs_f32();
        if elapsed >= 0.25 {
            let delta = visited.saturating_sub(self.last_visited);
            self.speed_dirs_per_sec = delta as f32 / elapsed;
            self.last_visited = visited;
            self.last_time = Instant::now();
        }
    }

    fn reset(&mut self) {
        *self = SpeedTracker::new();
    }
}

// ─── Progress channel ────────────────────────────────────────────────────────

struct ChannelProgress {
    tx: mpsc::Sender<ScanProgressSnapshot>,
    paused: Arc<AtomicBool>,
}

impl ScanProgressPort for ChannelProgress {
    fn on_progress(&self, snapshot: ScanProgressSnapshot) {
        let _ = self.tx.send(snapshot);
    }

    fn is_paused(&self) -> bool {
        self.paused.load(Ordering::Relaxed)
    }
}

// ─── UI state ────────────────────────────────────────────────────────────────

struct DesktopCleanerUi {
    app: Arc<CleanerApp>,
    step: Step,
    status: String,

    // Aba Configurar
    root_path: String,
    targets_list: Vec<TargetEntry>,
    new_target_input: String,
    selected_mode: ScanMode,

    // Scan channels & state
    scan_rx: Option<Receiver<Result<ScanResult, String>>>,
    scan_progress_rx: Option<Receiver<ScanProgressSnapshot>>,
    clean_rx: Option<Receiver<Result<CleanResult, String>>>,
    scan_started_at: Option<Instant>,
    scan_min_visible_until: Option<Instant>,
    scan_pause_flag: Arc<AtomicBool>,
    active_scan_mode: ScanMode,
    progress_snapshot: Option<ScanProgressSnapshot>,
    speed_tracker: SpeedTracker,
    is_cleaning: bool,
    clean_total: usize,

    // Resultados
    rows: Vec<RowState>,
    total_bytes: u64,

    // Filtro e ordenação
    sort_column: SortColumn,
    sort_asc: bool,
    search_query: String,
    filtered_indices: Vec<usize>,
}

impl DesktopCleanerUi {
    fn new(app: Arc<CleanerApp>) -> Self {
        let (targets_list, initial_status) = match app.load_learning() {
            Ok(learning) => {
                let list = build_targets_list(&learning);
                (list, "Defina a pasta raiz e clique em Iniciar Scan".to_string())
            }
            Err(e) => {
                eprintln!("Aviso: falha ao carregar estado ({e}), usando padrões");
                let defaults: Vec<TargetEntry> = default_targets_vec()
                    .into_iter()
                    .map(|name| TargetEntry { name, is_custom: false, enabled: true })
                    .collect();
                (defaults, "Estado local inválido, usando configuração padrão".to_string())
            }
        };

        Self {
            app,
            step: Step::Configure,
            status: initial_status,
            root_path: String::new(),
            targets_list,
            new_target_input: String::new(),
            selected_mode: ScanMode::Full,
            scan_rx: None,
            scan_progress_rx: None,
            clean_rx: None,
            scan_started_at: None,
            scan_min_visible_until: None,
            scan_pause_flag: Arc::new(AtomicBool::new(false)),
            active_scan_mode: ScanMode::Full,
            progress_snapshot: Some(ScanProgressSnapshot { visited_dirs: 0, matched_dirs: 0 }),
            speed_tracker: SpeedTracker::new(),
            is_cleaning: false,
            clean_total: 0,
            rows: Vec::new(),
            total_bytes: 0,
            sort_column: SortColumn::Size,
            sort_asc: false,
            search_query: String::new(),
            filtered_indices: Vec::new(),
        }
    }

    fn rebuild_targets_list(&mut self) {
        match self.app.load_learning() {
            Ok(learning) => {
                let prev_disabled: HashSet<String> = self
                    .targets_list
                    .iter()
                    .filter(|e| !e.enabled)
                    .map(|e| e.name.clone())
                    .collect();
                let mut list = build_targets_list(&learning);
                for e in &mut list {
                    if prev_disabled.contains(&e.name) {
                        e.enabled = false;
                    }
                }
                self.targets_list = list;
            }
            Err(e) => {
                self.status = format!("Erro ao carregar targets: {e}");
            }
        }
    }

    fn apply_sort_and_filter(&mut self) {
        self.rows.sort_by(|a, b| {
            let ord = match self.sort_column {
                SortColumn::Kind => a.kind.cmp(&b.kind),
                SortColumn::Path => a.path.cmp(&b.path),
                SortColumn::Size => a.bytes.cmp(&b.bytes),
            };
            if self.sort_asc { ord } else { ord.reverse() }
        });
        let q = self.search_query.trim().to_ascii_lowercase();
        self.filtered_indices = self.rows
            .iter()
            .enumerate()
            .filter(|(_, r)| {
                q.is_empty()
                    || r.path.to_string_lossy().to_ascii_lowercase().contains(&q)
                    || r.kind.to_ascii_lowercase().contains(&q)
            })
            .map(|(i, _)| i)
            .collect();
    }

    fn start_scan(&mut self) {
        let root = self.root_path.trim().to_string();
        if root.is_empty() {
            self.status = "Informe a pasta raiz".to_string();
            return;
        }
        let root_path = PathBuf::from(&root);
        if !root_path.exists() || !root_path.is_dir() {
            self.status = "Pasta raiz inválida ou inexistente".to_string();
            return;
        }

        let now = Instant::now();
        self.step = Step::Scanning;
        self.status = "Escaneando...".to_string();
        self.scan_started_at = Some(now);
        self.scan_min_visible_until = Some(now + Duration::from_millis(800));
        self.active_scan_mode = self.selected_mode;
        self.rows.clear();
        self.total_bytes = 0;
        self.filtered_indices.clear();
        self.progress_snapshot = Some(ScanProgressSnapshot { visited_dirs: 0, matched_dirs: 0 });
        self.scan_pause_flag.store(false, Ordering::Relaxed);
        self.speed_tracker.reset();

        let active_targets: Vec<String> = self
            .targets_list
            .iter()
            .filter(|e| e.enabled)
            .map(|e| e.name.clone())
            .collect();

        let app = self.app.clone();
        let (tx, rx) = mpsc::channel();
        let (progress_tx, progress_rx) = mpsc::channel();
        self.scan_rx = Some(rx);
        self.scan_progress_rx = Some(progress_rx);
        let mode = self.selected_mode;
        let pause_flag = self.scan_pause_flag.clone();
        let excluded = system_excluded_roots();
        std::thread::spawn(move || {
            let reporter = ChannelProgress { tx: progress_tx, paused: pause_flag };
            let result = app
                .scan_with_mode_and_progress(root_path, mode, Some(&reporter), excluded, active_targets)
                .map_err(|e| e.to_string());
            let _ = tx.send(result);
        });
    }

    fn start_clean(&mut self) {
        let root = self.root_path.trim().to_string();
        if root.is_empty() {
            self.status = "Informe a pasta raiz válida".to_string();
            return;
        }
        let selected_paths = self
            .rows
            .iter()
            .filter(|r| r.selected)
            .map(|r| r.path.clone())
            .collect::<Vec<_>>();
        if selected_paths.is_empty() {
            self.status = "Nenhum item selecionado".to_string();
            return;
        }
        self.clean_total = selected_paths.len();
        self.status = format!("Removendo {} itens...", selected_paths.len());
        self.is_cleaning = true;
        let app = self.app.clone();
        let (tx, rx) = mpsc::channel();
        self.clean_rx = Some(rx);
        std::thread::spawn(move || {
            let req = CleanRequest { scan_root: PathBuf::from(root), selected_paths };
            let result = app.clean(req).map_err(|e| e.to_string());
            let _ = tx.send(result);
        });
    }

    fn poll_background(&mut self, ctx: &egui::Context) {
        // Poll scan progress
        if let Some(progress_rx) = self.scan_progress_rx.take() {
            let mut keep = true;
            loop {
                match progress_rx.try_recv() {
                    Ok(snapshot) => {
                        self.speed_tracker.update(snapshot.visited_dirs);
                        self.progress_snapshot = Some(snapshot);
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => { keep = false; break; }
                }
            }
            if keep && matches!(self.step, Step::Scanning) {
                self.scan_progress_rx = Some(progress_rx);
            }
        }

        // Poll scan result
        if let Some(rx) = self.scan_rx.take() {
            if let Some(until) = self.scan_min_visible_until {
                if Instant::now() < until {
                    self.scan_rx = Some(rx);
                    ctx.request_repaint_after(Duration::from_millis(60));
                    return;
                }
            }
            match rx.try_recv() {
                Ok(result) => match result {
                    Ok(scan) => {
                        self.total_bytes = scan.total_bytes;
                        self.rows = scan.candidates.into_iter().map(|c| RowState {
                            path: c.path,
                            kind: c.kind,
                            bytes: c.bytes,
                            has_exact_size: self.active_scan_mode == ScanMode::Full,
                            selected: c.selected,
                        }).collect();
                        self.apply_sort_and_filter();
                        self.status = format!("Scan concluído: {} itens", self.rows.len());
                        self.step = Step::Review;
                        self.scan_min_visible_until = None;
                        self.scan_started_at = None;
                        self.scan_progress_rx = None;
                    }
                    Err(err) => {
                        self.status = format!("Erro no scan: {err}");
                        self.step = Step::Configure;
                        self.scan_min_visible_until = None;
                        self.scan_started_at = None;
                        self.scan_progress_rx = None;
                    }
                },
                Err(TryRecvError::Empty) => {
                    self.scan_rx = Some(rx);
                    ctx.request_repaint_after(Duration::from_millis(60));
                }
                Err(TryRecvError::Disconnected) => {
                    self.status = "Falha de comunicação no scan".to_string();
                    self.step = Step::Configure;
                    self.scan_progress_rx = None;
                }
            }
        }

        // Poll clean result
        if let Some(rx) = self.clean_rx.take() {
            match rx.try_recv() {
                Ok(result) => match result {
                    Ok(done) => {
                        let removed_set: HashSet<PathBuf> =
                            done.removed_paths.into_iter().collect();
                        self.rows.retain(|r| !removed_set.contains(&r.path));
                        self.total_bytes = self.rows.iter().map(|r| r.bytes).sum();
                        self.apply_sort_and_filter();
                        self.status = format!(
                            "Removidos {} itens ({})",
                            done.removed_count,
                            format_bytes(done.removed_bytes)
                        );
                        self.is_cleaning = false;
                    }
                    Err(err) => {
                        self.status = format!("Erro na remoção: {err}");
                        self.is_cleaning = false;
                    }
                },
                Err(TryRecvError::Empty) => {
                    self.clean_rx = Some(rx);
                    ctx.request_repaint_after(Duration::from_millis(60));
                }
                Err(TryRecvError::Disconnected) => {
                    self.status = "Falha de comunicação na remoção".to_string();
                    self.is_cleaning = false;
                }
            }
        }

        if matches!(self.step, Step::Scanning) || self.is_cleaning {
            ctx.request_repaint_after(Duration::from_millis(60));
        }
    }

    // ─── Tab contents ─────────────────────────────────────────────────────

    fn show_configure(&mut self, ui: &mut egui::Ui) {
        ui.add_space(8.0);

        // Root path selector
        ui.group(|ui| {
            ui.label(RichText::new("Pasta raiz").strong());
            ui.horizontal(|ui| {
                ui.label("Caminho:");
                ui.text_edit_singleline(&mut self.root_path);
                if ui.button("📂 Selecionar").clicked() {
                    if let Some(path) = FileDialog::new().pick_folder() {
                        self.root_path = path.display().to_string();
                        self.status = "Pasta raiz selecionada".to_string();
                    }
                }
            });
            ui.horizontal(|ui| {
                ui.label("Modo de scan:");
                ui.selectable_value(&mut self.selected_mode, ScanMode::Fast, "Fast")
                    .on_hover_text("Rápido: encontra as pastas sem calcular tamanhos");
                ui.selectable_value(&mut self.selected_mode, ScanMode::Full, "Full")
                    .on_hover_text("Completo: calcula o tamanho real de cada pasta (mais lento)");
            });
        });

        ui.add_space(8.0);

        // Targets list
        ui.group(|ui| {
            ui.horizontal(|ui| {
                ui.label(RichText::new("Pastas-alvo").strong());
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if ui.button("Restaurar padrões").clicked() {
                        match self.app.set_base_targets_csv(String::new()) {
                            Ok(_) => {
                                self.rebuild_targets_list();
                                self.status = "Padrões restaurados".to_string();
                            }
                            Err(e) => self.status = format!("Erro: {e}"),
                        }
                    }
                });
            });

            // Add new target row
            ui.horizontal(|ui| {
                let resp = ui.text_edit_singleline(&mut self.new_target_input);
                let add_pressed = resp.lost_focus()
                    && ui.input(|i| i.key_pressed(egui::Key::Enter));
                let can_add = !self.new_target_input.trim().is_empty();
                if (ui.add_enabled(can_add, egui::Button::new("+ Adicionar")).clicked()
                    || add_pressed)
                    && can_add
                {
                    let name = self.new_target_input.trim().to_string();
                    match self.app.add_custom_target(name.clone()) {
                        Ok(_) => {
                            self.new_target_input.clear();
                            self.rebuild_targets_list();
                            self.status = format!("'{name}' adicionado");
                        }
                        Err(e) => self.status = format!("Erro: {e}"),
                    }
                }
            });

            ui.separator();

            // Target entries
            let mut to_remove: Option<String> = None;
            egui::ScrollArea::vertical().max_height(160.0).id_salt("targets_scroll").show(ui, |ui| {
                for entry in &mut self.targets_list {
                    ui.horizontal(|ui| {
                        ui.checkbox(&mut entry.enabled, "");
                        let label = if entry.is_custom {
                            RichText::new(&entry.name).color(Color32::from_rgb(40, 150, 80))
                        } else {
                            RichText::new(&entry.name)
                        };
                        ui.label(label);
                        if entry.is_custom {
                            ui.label(
                                RichText::new("custom")
                                    .small()
                                    .color(Color32::from_rgb(40, 150, 80)),
                            );
                        }
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if ui.small_button("✕").on_hover_text("Remover permanentemente").clicked() {
                                to_remove = Some(entry.name.clone());
                            }
                        });
                    });
                }
            });
            if let Some(name) = to_remove {
                match self.app.remove_target(&name) {
                    Ok(_) => {
                        self.rebuild_targets_list();
                        self.status = format!("'{name}' removido");
                    }
                    Err(e) => self.status = format!("Erro: {e}"),
                }
            }

            // Hint: enabled count
            let enabled_count = self.targets_list.iter().filter(|e| e.enabled).count();
            let total_count = self.targets_list.len();
            if enabled_count < total_count {
                ui.add_space(2.0);
                ui.label(
                    RichText::new(format!("{enabled_count} de {total_count} targets ativos no próximo scan"))
                        .small()
                        .color(Color32::from_rgb(180, 130, 0)),
                );
            }
        });

        ui.add_space(12.0);

        let scanning = matches!(self.step, Step::Scanning);
        let can_scan = !scanning && !self.is_cleaning && !self.root_path.trim().is_empty();
        if ui
            .add_enabled(
                can_scan,
                egui::Button::new(RichText::new("🔍 Iniciar Scan").size(15.0))
                    .min_size(egui::vec2(140.0, 32.0)),
            )
            .clicked()
        {
            self.start_scan();
        }
    }

    fn show_scanning(&mut self, ui: &mut egui::Ui) {
        let paused = self.scan_pause_flag.load(Ordering::Relaxed);
        let snapshot = self.progress_snapshot.unwrap_or(ScanProgressSnapshot {
            visited_dirs: 0,
            matched_dirs: 0,
        });

        ui.add_space(30.0);
        ui.vertical_centered(|ui| {
            if paused {
                ui.label(
                    RichText::new("⏸ PAUSADO")
                        .size(28.0)
                        .color(Color32::from_rgb(210, 150, 0)),
                );
            } else {
                ui.add(egui::Spinner::new().size(48.0));
            }

            ui.add_space(16.0);

            if let Some(start) = self.scan_started_at {
                ui.label(
                    RichText::new(format!("Tempo: {}s", start.elapsed().as_secs())).size(13.0),
                );
            }

            ui.add_space(8.0);

            let stats_text = if paused {
                format!(
                    "Visitadas: {}  |  Encontradas: {}  |  pausado",
                    format_number(snapshot.visited_dirs),
                    snapshot.matched_dirs
                )
            } else {
                format!(
                    "Visitadas: {}  |  Encontradas: {}  |  {:.0} dirs/s",
                    format_number(snapshot.visited_dirs),
                    snapshot.matched_dirs,
                    self.speed_tracker.speed_dirs_per_sec
                )
            };
            ui.label(RichText::new(stats_text).size(13.0));

            ui.add_space(12.0);

            if !paused {
                ui.add(
                    egui::ProgressBar::new(0.5)
                        .animate(true)
                        .desired_width(320.0)
                        .text("Scan em andamento"),
                );
            }

            ui.add_space(20.0);

            if ui
                .button(
                    RichText::new(if paused { "▶ Retomar" } else { "⏸ Pausar" }).size(14.0),
                )
                .clicked()
            {
                self.scan_pause_flag.store(!paused, Ordering::Relaxed);
            }
        });
    }

    fn show_review(&mut self, ui: &mut egui::Ui) {
        // Cleaning overlay — shows prominently while deletion is in progress
        if self.is_cleaning {
            ui.add_space(40.0);
            ui.vertical_centered(|ui| {
                ui.add(egui::Spinner::new().size(48.0));
                ui.add_space(16.0);
                ui.label(
                    RichText::new(format!("Removendo {} itens...", self.clean_total))
                        .size(18.0)
                        .strong(),
                );
                ui.add_space(8.0);
                ui.add(
                    egui::ProgressBar::new(0.5)
                        .animate(true)
                        .desired_width(300.0)
                        .text("Aguarde, isso pode levar alguns segundos"),
                );
            });
            return;
        }

        let is_fast_mode = self.active_scan_mode == ScanMode::Fast;
        let selected_count = self.rows.iter().filter(|r| r.selected).count();
        let selected_bytes: u64 =
            self.rows.iter().filter(|r| r.selected).map(|r| r.bytes).sum();
        let total_count = self.rows.len();

        ui.add_space(6.0);

        // Stats bar
        ui.horizontal(|ui| {
            if is_fast_mode {
                ui.label(format!("Encontrado: {total_count} itens"));
                ui.separator();
                ui.label(format!("Selecionado: {selected_count} itens"))
                    .on_hover_text("Tamanhos não disponíveis no modo Fast");
            } else {
                ui.label(format!(
                    "Encontrado: {total_count} itens  ({})",
                    format_bytes(self.total_bytes)
                ));
                ui.separator();
                ui.label(format!(
                    "Selecionado: {selected_count} itens  ({})",
                    format_bytes(selected_bytes)
                ));
            }
        });

        ui.add_space(4.0);

        // Action buttons
        ui.horizontal(|ui| {
            if ui.button("Marcar todos").clicked() {
                for r in &mut self.rows {
                    r.selected = true;
                }
            }
            if ui.button("Desmarcar todos").clicked() {
                for r in &mut self.rows {
                    r.selected = false;
                }
            }
            let can_clean = selected_count > 0;
            if ui
                .add_enabled(can_clean, egui::Button::new("🗑 Remover selecionados"))
                .clicked()
            {
                let confirm = MessageDialog::new()
                    .set_level(MessageLevel::Warning)
                    .set_title("Confirmar remoção")
                    .set_description(format!(
                        "Remover {selected_count} itens selecionados? Esta ação é irreversível."
                    ))
                    .set_buttons(MessageButtons::YesNo)
                    .show();
                if confirm == MessageDialogResult::Yes {
                    self.start_clean();
                }
            }
        });

        ui.add_space(4.0);

        // Search bar
        ui.horizontal(|ui| {
            ui.label("🔍");
            let changed = ui
                .add(
                    egui::TextEdit::singleline(&mut self.search_query)
                        .hint_text("Filtrar por caminho ou tipo...")
                        .desired_width(280.0),
                )
                .changed();
            if changed {
                self.apply_sort_and_filter();
            }
            if !self.search_query.is_empty() {
                if ui.small_button("✕").clicked() {
                    self.search_query.clear();
                    self.apply_sort_and_filter();
                }
                ui.label(format!("{} resultado(s)", self.filtered_indices.len()));
            }
        });

        ui.add_space(4.0);

        // Column headers (sortable)
        let col_kind = sort_header_label("Tipo", self.sort_column == SortColumn::Kind, self.sort_asc);
        let col_path = sort_header_label("Caminho", self.sort_column == SortColumn::Path, self.sort_asc);
        let col_size = sort_header_label("Tamanho", self.sort_column == SortColumn::Size, self.sort_asc);

        ui.horizontal(|ui| {
            ui.add_space(20.0); // checkbox width
            if ui.button(col_kind).clicked() {
                if self.sort_column == SortColumn::Kind {
                    self.sort_asc = !self.sort_asc;
                } else {
                    self.sort_column = SortColumn::Kind;
                    self.sort_asc = true;
                }
                self.apply_sort_and_filter();
            }
            if ui.button(col_path).clicked() {
                if self.sort_column == SortColumn::Path {
                    self.sort_asc = !self.sort_asc;
                } else {
                    self.sort_column = SortColumn::Path;
                    self.sort_asc = true;
                }
                self.apply_sort_and_filter();
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                if ui.button(col_size).clicked() {
                    if self.sort_column == SortColumn::Size {
                        self.sort_asc = !self.sort_asc;
                    } else {
                        self.sort_column = SortColumn::Size;
                        self.sort_asc = false;
                    }
                    self.apply_sort_and_filter();
                }
            });
        });

        ui.separator();

        // Virtual-scrolling results list
        let root = PathBuf::from(self.root_path.trim());
        let indices_snapshot = self.filtered_indices.clone();
        let num_visible = indices_snapshot.len();
        let rows = &mut self.rows;

        egui::ScrollArea::vertical()
            .id_salt("results_scroll")
            .show_rows(ui, 28.0, num_visible, |ui, row_range| {
                for display_i in row_range {
                    let row = &mut rows[indices_snapshot[display_i]];
                    ui.horizontal(|ui| {
                        ui.checkbox(&mut row.selected, "");
                        ui.label(
                            RichText::new(&row.kind).color(Color32::from_rgb(30, 102, 161)),
                        );
                        let display_path = row
                            .path
                            .strip_prefix(&root)
                            .map(|p| p.display().to_string())
                            .unwrap_or_else(|_| row.path.display().to_string());
                        ui.label(display_path);
                        ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                            if row.has_exact_size {
                                ui.label(format_bytes(row.bytes));
                            } else {
                                ui.label("--");
                            }
                        });
                    });
                    ui.separator();
                }
            });
    }
}

// ─── egui App ────────────────────────────────────────────────────────────────

impl eframe::App for DesktopCleanerUi {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_background(ctx);

        let is_scanning = matches!(self.step, Step::Scanning);
        let has_results = !self.rows.is_empty();

        // Tab bar
        egui::TopBottomPanel::top("tab_bar").show(ctx, |ui| {
            ui.add_space(4.0);
            ui.horizontal(|ui| {
                ui.heading(
                    RichText::new("Clear Dev Cache")
                        .size(16.0)
                        .color(Color32::from_rgb(25, 35, 45)),
                );
                ui.separator();

                let is_configure = matches!(self.step, Step::Configure);
                if ui
                    .selectable_label(is_configure, "⚙ Configurar")
                    .clicked()
                    && !is_scanning
                {
                    self.step = Step::Configure;
                }

                if is_scanning {
                    ui.add(egui::Spinner::new().size(14.0));
                    ui.colored_label(Color32::from_rgb(210, 150, 0), "🔍 Escaneando");
                } else {
                    ui.label(RichText::new("🔍 Scan").color(Color32::GRAY));
                }

                let results_label = if has_results {
                    format!("📋 Resultados ({})", self.rows.len())
                } else {
                    "📋 Resultados".to_string()
                };
                let is_review = matches!(self.step, Step::Review);
                if ui
                    .add_enabled(
                        has_results && !is_scanning,
                        egui::Button::selectable(is_review, results_label),
                    )
                    .clicked()
                {
                    self.step = Step::Review;
                }
            });
            ui.add_space(2.0);
        });

        // Status bar
        egui::TopBottomPanel::bottom("status_bar").show(ctx, |ui| {
            ui.add_space(2.0);
            ui.colored_label(
                Color32::from_rgb(60, 90, 120),
                format!("Status: {}", self.status),
            );
            ui.add_space(2.0);
        });

        // Main content
        egui::CentralPanel::default().show(ctx, |ui| match self.step {
            Step::Configure => self.show_configure(ui),
            Step::Scanning => self.show_scanning(ui),
            Step::Review => self.show_review(ui),
        });
    }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn build_targets_list(learning: &domain::AppLearningState) -> Vec<TargetEntry> {
    let defaults: HashSet<String> = default_targets_vec().into_iter().collect();
    let rules = domain::GarbageRules::new(&learning.base_targets, &learning.custom_targets);
    let mut list: Vec<TargetEntry> = rules
        .all_targets()
        .into_iter()
        .map(|name| TargetEntry { is_custom: !defaults.contains(&name), name, enabled: true })
        .collect();
    list.sort_by(|a, b| a.is_custom.cmp(&b.is_custom).then(a.name.cmp(&b.name)));
    list
}

fn sort_header_label(title: &str, is_active: bool, sort_asc: bool) -> String {
    if is_active {
        format!("{} {}", title, if sort_asc { "↑" } else { "↓" })
    } else {
        format!("{} ↕", title)
    }
}

fn format_number(n: usize) -> String {
    let s = n.to_string();
    let mut chars: Vec<char> = Vec::with_capacity(s.len() + s.len() / 3);
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            chars.push('.');
        }
        chars.push(c);
    }
    chars.into_iter().rev().collect()
}

fn format_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = KB * 1024.0;
    const GB: f64 = MB * 1024.0;
    let b = bytes as f64;
    if b >= GB {
        format!("{:.2} GB", b / GB)
    } else if b >= MB {
        format!("{:.2} MB", b / MB)
    } else if b >= KB {
        format!("{:.2} KB", b / KB)
    } else {
        format!("{bytes} B")
    }
}
