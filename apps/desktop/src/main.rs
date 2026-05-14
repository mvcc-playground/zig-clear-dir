use anyhow::Result;
use application::{CleanerApp, ScanProgressPort, ScanProgressSnapshot};
use domain::{CleanRequest, CleanResult, ScanMode, ScanResult, default_targets_vec};
use eframe::egui::{self, Color32, RichText};
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

    let native_options = eframe::NativeOptions::default();
    eframe::run_native(
        "Clear Dev Cache",
        native_options,
        Box::new(|_cc| Ok(Box::new(DesktopCleanerUi::new(app)))),
    )
    .map_err(|e| anyhow::anyhow!("eframe error: {e}"))?;

    Ok(())
}

#[derive(Clone)]
struct RowState {
    path: PathBuf,
    kind: String,
    bytes: u64,
    has_exact_size: bool,
    selected: bool,
}

enum Step {
    Configure,
    Scanning,
    Review,
}

struct DesktopCleanerUi {
    app: Arc<CleanerApp>,
    step: Step,
    status: String,
    root_path: String,
    base_targets_csv: String,
    custom_target_input: String,
    available_targets: String,
    total_bytes: u64,
    rows: Vec<RowState>,
    scan_rx: Option<Receiver<Result<ScanResult, String>>>,
    scan_progress_rx: Option<Receiver<ScanProgressSnapshot>>,
    clean_rx: Option<Receiver<Result<CleanResult, String>>>,
    scan_started_at: Option<Instant>,
    scan_min_visible_until: Option<Instant>,
    is_cleaning: bool,
    selected_mode: ScanMode,
    active_scan_mode: ScanMode,
    scan_last_mode: Option<ScanMode>,
    progress_snapshot: Option<ScanProgressSnapshot>,
    scan_pause_flag: Arc<AtomicBool>,
}

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

impl DesktopCleanerUi {
    fn new(app: Arc<CleanerApp>) -> Self {
        let (base_targets_csv, available_targets, initial_status) = match app.load_learning() {
            Ok(learning) => {
                let base = if learning.base_targets.is_empty() {
                    default_targets_vec()
                } else {
                    learning.base_targets.clone()
                };
                let rules = domain::GarbageRules::new(&learning.base_targets, &learning.custom_targets);
                (
                    base.join(","),
                    rules.all_targets().join(", "),
                    "Defina as pastas e clique em Iniciar scan".to_string(),
                )
            }
            Err(e) => {
                eprintln!("Aviso: falha ao carregar estado ({e}), usando padrões");
                let base = default_targets_vec();
                (
                    base.join(","),
                    base.join(", "),
                    "Estado local inválido, usando configuração padrão".to_string(),
                )
            }
        };
        Self {
            app,
            step: Step::Configure,
            status: initial_status,
            root_path: String::new(),
            base_targets_csv,
            custom_target_input: String::new(),
            available_targets,
            total_bytes: 0,
            rows: Vec::new(),
            scan_rx: None,
            scan_progress_rx: None,
            clean_rx: None,
            scan_started_at: None,
            scan_min_visible_until: None,
            is_cleaning: false,
            selected_mode: ScanMode::Fast,
            active_scan_mode: ScanMode::Fast,
            scan_last_mode: None,
            progress_snapshot: None,
            scan_pause_flag: Arc::new(AtomicBool::new(false)),
        }
    }

    fn start_scan(&mut self) {
        match self.app.set_base_targets_csv(self.base_targets_csv.clone()) {
            Ok(targets) => self.available_targets = targets.join(", "),
            Err(err) => {
                self.status = format!("Erro ao salvar alvos padrão: {err}");
                return;
            }
        }

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
        self.scan_last_mode = Some(self.selected_mode);
        self.rows.clear();
        self.total_bytes = 0;
        self.progress_snapshot = Some(ScanProgressSnapshot {
            visited_dirs: 0,
            matched_dirs: 0,
        });
        self.scan_pause_flag.store(false, Ordering::Relaxed);

        let app = self.app.clone();
        let (tx, rx) = mpsc::channel();
        let (progress_tx, progress_rx) = mpsc::channel();
        self.scan_rx = Some(rx);
        self.scan_progress_rx = Some(progress_rx);
        let mode = self.selected_mode;
        let pause_flag = self.scan_pause_flag.clone();
        let excluded = system_excluded_roots();
        std::thread::spawn(move || {
            let reporter = ChannelProgress {
                tx: progress_tx,
                paused: pause_flag,
            };
            let result = app
                .scan_with_mode_and_progress(root_path, mode, Some(&reporter), excluded)
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
        self.status = "Removendo itens selecionados...".to_string();
        self.is_cleaning = true;
        let app = self.app.clone();
        let (tx, rx) = mpsc::channel();
        self.clean_rx = Some(rx);
        std::thread::spawn(move || {
            let req = CleanRequest {
                scan_root: PathBuf::from(root),
                selected_paths,
            };
            let result = app.clean(req).map_err(|e| e.to_string());
            let _ = tx.send(result);
        });
    }

    fn poll_background(&mut self, ctx: &egui::Context) {
        if let Some(progress_rx) = self.scan_progress_rx.take() {
            let mut keep = true;
            loop {
                match progress_rx.try_recv() {
                    Ok(snapshot) => self.progress_snapshot = Some(snapshot),
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        keep = false;
                        break;
                    }
                }
            }
            if keep && matches!(self.step, Step::Scanning) {
                self.scan_progress_rx = Some(progress_rx);
            }
        }

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
                        self.rows = scan
                            .candidates
                            .into_iter()
                            .map(|c| RowState {
                                path: c.path,
                                kind: c.kind,
                                bytes: c.bytes,
                                has_exact_size: self.active_scan_mode == ScanMode::Full,
                                selected: c.selected,
                            })
                            .collect();
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

        if let Some(rx) = self.clean_rx.take() {
            match rx.try_recv() {
                Ok(result) => match result {
                    Ok(done) => {
                        let removed_set: HashSet<PathBuf> = done.removed_paths.into_iter().collect();
                        self.rows.retain(|r| !removed_set.contains(&r.path));
                        self.total_bytes = self.rows.iter().map(|r| r.bytes).sum();
                        self.status = format!(
                            "Removidos {} itens ({})",
                            done.removed_count,
                            format_bytes(done.removed_bytes)
                        );
                        self.step = Step::Review;
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
    }
}

impl eframe::App for DesktopCleanerUi {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_background(ctx);

        egui::TopBottomPanel::top("header").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading(RichText::new("Clear Dev Cache").color(Color32::from_rgb(25, 35, 45)));
                ui.separator();
                ui.label("Passo 1: Configurar | Passo 2: Scan | Passo 3: Revisar e Remover");
            });
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            ui.add_space(8.0);

            ui.group(|ui| {
                ui.label(RichText::new("Passo 1 - O que buscar").strong());
                ui.horizontal(|ui| {
                    ui.label("Pasta raiz:");
                    ui.text_edit_singleline(&mut self.root_path);
                    if ui.button("Selecionar pasta").clicked() {
                        if let Some(path) = FileDialog::new().pick_folder() {
                            self.root_path = path.display().to_string();
                            self.status = "Pasta raiz selecionada".to_string();
                        }
                    }
                });
                ui.horizontal(|ui| {
                    ui.label("Pastas padrão (CSV):");
                    ui.text_edit_singleline(&mut self.base_targets_csv);
                });
                ui.horizontal(|ui| {
                    ui.label("Modo de scan:");
                    ui.selectable_value(&mut self.selected_mode, ScanMode::Fast, "Fast")
                        .on_hover_text("Rápido: encontra as pastas sem calcular tamanhos");
                    ui.selectable_value(&mut self.selected_mode, ScanMode::Full, "Full")
                        .on_hover_text("Completo: calcula o tamanho real de cada pasta (mais lento)");
                });
                ui.horizontal(|ui| {
                    if ui.button("Salvar pastas padrão").clicked() {
                        match self.app.set_base_targets_csv(self.base_targets_csv.clone()) {
                            Ok(targets) => {
                                self.available_targets = targets.join(", ");
                                self.status = "Pastas padrão salvas".to_string();
                            }
                            Err(err) => self.status = format!("Erro: {err}"),
                        }
                    }
                    ui.label("Adicionar pasta extra:");
                    ui.text_edit_singleline(&mut self.custom_target_input);
                    if ui.button("Adicionar").clicked() {
                        match self.app.add_custom_target(self.custom_target_input.clone()) {
                            Ok(targets) => {
                                self.available_targets = targets.join(", ");
                                self.custom_target_input.clear();
                                self.status = "Pasta extra adicionada".to_string();
                            }
                            Err(err) => self.status = format!("Erro: {err}"),
                        }
                    }
                });
                ui.label(format!("Alvos ativos: {}", self.available_targets));
            });

            ui.add_space(10.0);
            ui.group(|ui| {
                ui.label(RichText::new("Passo 2 - Executar scan").strong());
                let scanning = matches!(self.step, Step::Scanning);
                let can_scan = !scanning && !self.is_cleaning;
                if ui
                    .add_enabled(can_scan, egui::Button::new("Iniciar scan"))
                    .clicked()
                {
                    self.start_scan();
                }
                if scanning {
                    let paused = self.scan_pause_flag.load(Ordering::Relaxed);
                    if ui
                        .button(if paused { "▶ Retomar scan" } else { "⏸ Pausar scan" })
                        .clicked()
                    {
                        self.scan_pause_flag.store(!paused, Ordering::Relaxed);
                    }
                    if paused {
                        ui.label(RichText::new("⏸ PAUSADO").color(Color32::from_rgb(200, 140, 0)));
                    } else {
                        ui.add(egui::Spinner::new());
                    }
                    if let Some(start) = self.scan_started_at {
                        ui.label(format!("{}s", start.elapsed().as_secs()));
                    }
                    let snapshot = self.progress_snapshot.unwrap_or(ScanProgressSnapshot {
                        visited_dirs: 0,
                        matched_dirs: 0,
                    });
                    ui.label(format!(
                        "Visitadas: {} | Candidatas: {}",
                        snapshot.visited_dirs,
                        snapshot.matched_dirs,
                    ));
                    if !paused {
                        ui.add(
                            egui::ProgressBar::new(0.5)
                                .animate(true)
                                .text("Scan em andamento"),
                        );
                    }
                }
            });

            ui.add_space(10.0);
            ui.group(|ui| {
                let mode_label = match self.scan_last_mode.unwrap_or(self.active_scan_mode) {
                    ScanMode::Fast => "Fast",
                    ScanMode::Full => "Full",
                };
                ui.label(
                    RichText::new(format!(
                        "Passo 3 - Revisar e remover (resultado do modo {mode_label})"
                    ))
                    .strong(),
                );
                let is_fast_mode = self.active_scan_mode == ScanMode::Fast;
                let selected_count = self.rows.iter().filter(|r| r.selected).count();
                let selected_bytes: u64 = self.rows.iter()
                    .filter(|r| r.selected)
                    .map(|r| r.bytes)
                    .sum();

                ui.horizontal(|ui| {
                    if ui.button("Novo scan").clicked() {
                        self.step = Step::Configure;
                        self.rows.clear();
                        self.total_bytes = 0;
                        self.progress_snapshot = None;
                        self.status = "Pronto para novo scan".to_string();
                    }
                    if ui.button("Marcar todos").clicked() {
                        for row in &mut self.rows {
                            row.selected = true;
                        }
                    }
                    if ui.button("Desmarcar todos").clicked() {
                        for row in &mut self.rows {
                            row.selected = false;
                        }
                    }
                    let can_clean = !matches!(self.step, Step::Scanning) && !self.is_cleaning;
                    if ui
                        .add_enabled(can_clean, egui::Button::new("Remover selecionados"))
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
                    if self.is_cleaning {
                        ui.add(egui::Spinner::new());
                        ui.label("Removendo...");
                    }
                });
                ui.horizontal(|ui| {
                    if is_fast_mode {
                        ui.label(format!("Encontrado: {} itens", self.rows.len()));
                        ui.separator();
                        ui.label(format!("Selecionado: {selected_count} itens"))
                            .on_hover_text("Tamanhos não disponíveis no modo Fast");
                    } else {
                        ui.label(format!("Encontrado: {} itens ({})", self.rows.len(), format_bytes(self.total_bytes)));
                        ui.separator();
                        ui.label(format!("Selecionado: {selected_count} itens ({})", format_bytes(selected_bytes)));
                    }
                });

                let root = PathBuf::from(self.root_path.trim());
                let num_rows = self.rows.len();
                let rows = &mut self.rows;
                egui::ScrollArea::vertical()
                    .max_height(350.0)
                    .show_rows(ui, 28.0, num_rows, |ui, row_range| {
                        for idx in row_range {
                            let row = &mut rows[idx];
                            ui.horizontal(|ui| {
                                ui.checkbox(&mut row.selected, "");
                                ui.label(RichText::new(&row.kind).color(Color32::from_rgb(30, 102, 161)));
                                let display_path = row
                                    .path
                                    .strip_prefix(&root)
                                    .map(|p| p.display().to_string())
                                    .unwrap_or_else(|_| row.path.display().to_string());
                                ui.label(display_path);
                                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
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
            });

            ui.add_space(8.0);
            ui.colored_label(Color32::from_rgb(24, 58, 87), format!("Status: {}", self.status));
        });
    }
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
