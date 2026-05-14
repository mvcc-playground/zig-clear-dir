use application::ScannerPort;
use domain::{AppLearningState, ScanMode, ScanRequest};
use platform::NativeFsBackend;
use std::env;
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    let root = env::args().nth(1).unwrap_or_else(|| ".".to_string());
    let iterations = env::args()
        .nth(2)
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(3);
    let mode = env::args().nth(3).unwrap_or_else(|| "full".to_string());
    let scan_mode = if mode.eq_ignore_ascii_case("fast") {
        ScanMode::Fast
    } else {
        ScanMode::Full
    };

    let backend = NativeFsBackend;
    let learning = AppLearningState::default();
    let req = ScanRequest {
        root: PathBuf::from(root),
        mode: scan_mode,
    };

    println!("scan benchmark start");
    println!("iterations: {iterations}");
    println!("mode: {mode}");
    println!("root: {}", req.root.display());

    let mut best_ms = u128::MAX;
    let mut last_count = 0usize;
    let mut last_bytes = 0u64;

    for i in 0..iterations {
        let start = Instant::now();
        let result = backend.scan(&req, &learning).expect("scan failed");
        let elapsed = start.elapsed().as_millis();
        let total_bytes: u64 = result.iter().map(|v| v.bytes).sum();
        best_ms = best_ms.min(elapsed);
        last_count = result.len();
        last_bytes = total_bytes;
        println!(
            "run {} => {} ms | items: {} | total: {} bytes",
            i + 1,
            elapsed,
            last_count,
            last_bytes
        );
    }

    println!("best: {} ms", best_ms);
    println!("last items: {}", last_count);
    println!("last bytes: {}", last_bytes);
}
