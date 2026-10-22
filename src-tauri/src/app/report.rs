//! "Report a problem": a text file with what an issue needs, saved to Downloads and shown in
//! Explorer or the Finder, then GitHub's new-issue form with the version, OS and phone filled in. Nothing
//! is sent anywhere by the app: the user reads the file and attaches it.

use std::path::PathBuf;

use super::Controller;
use crate::{diag, platform, portable};

const NEW_ISSUE: &str = "https://github.com/Qwinty/plugcam/issues/new?template=bug.yml";

/// Saves the report and shows it, and opens the issue form. Returns the file's path.
pub fn create(c: &Controller) -> Result<PathBuf, String> {
    let text = diag::redact(&build(c));
    let dir = platform::downloads_dir().or_else(diag::log_dir).ok_or("no folder for the report")?;
    let stamp = jiff::Timestamp::now().strftime("%Y%m%d-%H%M%S");
    let path = dir.join(format!("plugcam-report-{stamp}.txt"));
    std::fs::write(&path, text).map_err(|e| format!("{}: {e}", path.display()))?;
    log::info!("report saved");

    platform::reveal(&path);
    let mut url = format!("{NEW_ISSUE}&version={}", encode(env!("CARGO_PKG_VERSION")));
    // The issue form's field is named `windows`; it takes the macOS version too.
    url += &format!("&windows={}", encode(&platform::os_name()));
    if let Some(phone) = c.phone_summary() {
        url += &format!("&phone={}", encode(&phone));
    }
    let _ = platform::open(&url);
    Ok(path)
}

/// Opens the folder with the log files.
pub fn open_log_folder() -> Result<(), String> {
    let dir = diag::log_dir().ok_or("no log folder")?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    platform::open(&dir.to_string_lossy())
}

fn build(c: &Controller) -> String {
    let mut out = String::from("Plugcam diagnostic report\n");
    out += "Review it before sharing: it has no passwords or files, but it names your phone and PC.\n";
    out += "Times are UTC.\n\n";
    out += &format!("Created: {:.0}\n", jiff::Timestamp::now());
    out += &format!(
        "Plugcam {} ({})\n",
        env!("CARGO_PKG_VERSION"),
        if portable::is_portable() { "portable" } else { "installed" }
    );
    out += &format!("{}\n", platform::os_name());
    let gpus = platform::gpu_names();
    out += &format!("GPU: {}\n", if gpus.is_empty() { "none found".into() } else { gpus.join("; ") });
    out += &format!(
        "Camera: {}\n",
        platform::vcam_registered_path().unwrap_or_else(|| "not registered".into())
    );
    out += &format!("Detailed log: {}\n", if diag::is_detailed() { "on" } else { "off" });
    out += &c.report_facts();

    if let Some(crash) = diag::crash_log() {
        out += "\n===== last-crash.log =====\n";
        out += &crash;
    }
    for (title, log) in diag::report_logs() {
        out += &format!("\n===== Log ({title}) =====\n");
        out += &log;
    }
    out
}

/// Percent-encodes a query value.
fn encode(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => out.push(b as char),
            _ => out += &format!("%{b:02X}"),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::encode;

    #[test]
    fn encodes_query_values() {
        assert_eq!(encode("OnePlus 11R, Android 15"), "OnePlus%2011R%2C%20Android%2015");
        assert_eq!(encode("0.1.1"), "0.1.1");
        assert_eq!(encode("é"), "%C3%A9");
    }
}
