use anyhow::Result;
use application::CleanerApp;
use domain::{CleanRequest, ScanMode, ScanResult, default_targets_vec};
use eframe::egui::{self, Color32, RichText};
use platform::NativeFsBackend;
use preferences::JsonLearningStore;
use rfd::FileDialog;
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, TryRecvError};
use std::time::{Duration, Instant};

fn main() -> Result<()> {
    let backend = Arc::new(NativeFsBackend);
    let learning = Arc::new(JsonLearningStore::new());
    let app = Arc::new(CleanerApp::new(backend.clone(), backend, learning));

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
    clean_rx: Option<Receiver<Result<(usize, u64), String>>>,
    scan_started_at: Option<Instant>,
    scan_min_visible_until: Option<Instant>,
    is_cleaning: bool,
    selected_mode: ScanMode,
}

impl DesktopCleanerUi {
    fn new(app: Arc<CleanerApp>) -> Self {
        let (base_targets_csv, available_targets) = match app.load_learning() {
            Ok(learning) => {
                let base = if learning.base_targets.is_empty() {
                    default_targets_vec()
                } else {
                    learning.base_targets.clone()
                };
                let rules = domain::GarbageRules::new(&learning.base_targets, &learning.custom_targets);
                (base.join(","), rules.all_targets().join(", "))
            }
            Err(_) => {
                let base = default_targets_vec();
                (base.join(","), base.join(", "))
            }
        };
        Self {
            app,
            step: Step::Configure,
            status: "Defina as pastas e clique em Iniciar Scan".to_string(),
            root_path: String::new(),
            base_targets_csv,
            custom_target_input: String::new(),
            available_targets,
            total_bytes: 0,
            rows: Vec::new(),
            scan_rx: None,
            clean_rx: None,
            scan_started_at: None,
            scan_min_visible_until: None,
            is_cleaning: false,
            selected_mode: ScanMode::Fast,
        }
    }

    fn start_scan(&mut self) {
        let root = self.root_path.trim().to_string();
        if root.is_empty() {
            self.status = "Informe a pasta raiz".to_string();
            return;
        }
        self.step = Step::Scanning;
        self.status = "Escaneando...".to_string();
        self.scan_started_at = Some(Instant::now());
        self.scan_min_visible_until = Some(Instant::now() + Duration::from_millis(800));
        self.rows.clear();
        self.total_bytes = 0;

        let app = self.app.clone();
        let (tx, rx) = mpsc::channel();
        self.scan_rx = Some(rx);
        let mode = self.selected_mode;
        std::thread::spawn(move || {
            let result = app
                .scan_with_mode(PathBuf::from(root), mode)
                .map_err(|e| e.to_string());
            let _ = tx.send(result);
        });
    }

    fn start_clean(&mut self) {
        let root = self.root_path.trim().to_string();
        if root.is_empty() {
            self.status = "Informe a pasta raiz valida".to_string();
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
            let result = app
                .clean(req)
                .map(|v| (v.removed_count, v.removed_bytes))
                .map_err(|e| e.to_string());
            let _ = tx.send(result);
        });
    }

    fn poll_background(&mut self) {
        if let Some(rx) = self.scan_rx.take() {
            match rx.try_recv() {
                Ok(result) => match result {
                    Ok(scan) => {
                        if let Some(until) = self.scan_min_visible_until {
                            if Instant::now() < until {
                                self.scan_rx = Some(rx);
                                return;
                            }
                        }
                        self.total_bytes = scan.total_bytes;
                        self.rows = scan
                            .candidates
                            .into_iter()
                            .map(|c| RowState {
                                path: c.path,
                                kind: c.kind,
                                bytes: c.bytes,
                                selected: c.selected,
                            })
                            .collect();
                        self.status = format!("Scan concluido: {} itens", self.rows.len());
                        self.step = Step::Review;
                        self.scan_min_visible_until = None;
                    }
                    Err(err) => {
                        self.status = format!("Erro no scan: {err}");
                        self.step = Step::Configure;
                        self.scan_min_visible_until = None;
                    }
                },
                Err(TryRecvError::Empty) => {
                    self.scan_rx = Some(rx);
                }
                Err(TryRecvError::Disconnected) => {
                    self.status = "Falha de comunicacao no scan".to_string();
                    self.step = Step::Configure;
                }
            }
        }
        if let Some(rx) = self.clean_rx.take() {
            match rx.try_recv() {
                Ok(result) => match result {
                    Ok((removed_count, removed_bytes)) => {
                        self.rows.retain(|r| !r.selected);
                        self.total_bytes = self.rows.iter().map(|r| r.bytes).sum();
                        self.status = format!(
                            "Removidos {} itens ({})",
                            removed_count,
                            format_bytes(removed_bytes)
                        );
                        self.step = Step::Review;
                        self.is_cleaning = false;
                    }
                    Err(err) => {
                        self.status = format!("Erro na remocao: {err}");
                        self.is_cleaning = false;
                    }
                },
                Err(TryRecvError::Empty) => {
                    self.clean_rx = Some(rx);
                }
                Err(TryRecvError::Disconnected) => {
                    self.status = "Falha de comunicacao na remocao".to_string();
                    self.is_cleaning = false;
                }
            }
        }
    }
}

impl eframe::App for DesktopCleanerUi {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.poll_background();
        ctx.request_repaint();

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
                    ui.label("Pastas padrao (CSV):");
                    ui.text_edit_singleline(&mut self.base_targets_csv);
                });
                ui.horizontal(|ui| {
                    ui.label("Modo de scan:");
                    ui.selectable_value(&mut self.selected_mode, ScanMode::Fast, "Fast");
                    ui.selectable_value(&mut self.selected_mode, ScanMode::Full, "Full");
                });
                ui.horizontal(|ui| {
                    if ui.button("Salvar pastas padrao").clicked() {
                        match self.app.set_base_targets_csv(self.base_targets_csv.clone()) {
                            Ok(targets) => {
                                self.available_targets = targets.join(", ");
                                self.status = "Pastas padrao salvas".to_string();
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
                let scan_button = ui.add_enabled(can_scan, egui::Button::new("Iniciar Scan"));
                if scan_button.clicked() {
                    self.start_scan();
                }
                if scanning {
                    ui.add(egui::Spinner::new());
                    if let Some(start) = self.scan_started_at {
                        ui.label(format!("Escaneando... {}s", start.elapsed().as_secs()));
                    }
                    let phase = self
                        .scan_started_at
                        .map(|s| ((s.elapsed().as_millis() % 1000) as f32) / 1000.0)
                        .unwrap_or(0.4);
                    ui.add(
                        egui::ProgressBar::new(phase)
                            .animate(true)
                            .text("Scan em andamento"),
                    );
                    ui.label("Clique recebido. Aguarde o scan finalizar.");
                }
            });

            ui.add_space(10.0);
            ui.group(|ui| {
                ui.label(RichText::new("Passo 3 - Revisar e remover").strong());
                ui.horizontal(|ui| {
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
                        self.start_clean();
                    }
                    if self.is_cleaning {
                        ui.add(egui::Spinner::new());
                        ui.label("Removendo...");
                    }
                    ui.label(format!("Total: {}", format_bytes(self.total_bytes)));
                });

                egui::ScrollArea::vertical().max_height(350.0).show(ui, |ui| {
                    for row in &mut self.rows {
                        ui.horizontal(|ui| {
                            ui.checkbox(&mut row.selected, "");
                            ui.label(RichText::new(&row.kind).color(Color32::from_rgb(30, 102, 161)));
                            ui.label(row.path.display().to_string());
                            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                                ui.label(format_bytes(row.bytes));
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
