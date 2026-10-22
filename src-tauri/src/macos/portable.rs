//! macOS has no portable build: Plugcam is an app bundle that keeps its data where macOS apps
//! do. These are the answers the rest of the app asks the portable module for.

use std::path::PathBuf;

pub fn is_portable() -> bool {
    false
}

/// Not used while `is_portable` is false; the app's own config folder.
pub fn data_dir() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default().join("Library/Application Support/io.github.plugcam")
}

/// Runs before the app starts. There are no helper jobs on macOS.
pub fn handle_args() -> Option<i32> {
    None
}

pub fn install_update(_bytes: &[u8]) -> Result<(), String> {
    Err("there is no portable version for macOS".into())
}
