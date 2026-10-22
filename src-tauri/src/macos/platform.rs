//! Small macOS facts the app needs: is the camera extension active, which macOS, what a bug
//! report says about the Mac, and installing the camera.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use crate::macos::{self, ErrorText};

/// How long the user has to approve the extension in System Settings.
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// The camera shows up a moment after macOS reports the extension active.
const APPEAR_TIMEOUT: Duration = Duration::from_secs(10);

/// What a report says about the camera when the extension is active.
pub fn vcam_registered_path() -> Option<String> {
    unsafe { macos::pc_camera_present() }.then(|| "camera extension active".into())
}

/// The app installs the camera itself (the extension in its bundle), not an installer.
pub fn app_manages_camera() -> bool {
    true
}

/// Installs (activates) or removes the camera extension. macOS asks the user to allow it in
/// System Settings the first time; this waits for that.
pub fn set_camera_registered(on: bool) -> Result<(), String> {
    let mut error = ErrorText::new();
    let timeout = APPROVAL_TIMEOUT.as_millis() as u32;
    match unsafe { macos::pc_camera_extension_request(on, timeout, error.ptr(), error.len()) } {
        0 => {}
        1 => return Err("not allowed in System Settings yet".into()),
        _ => return Err(error.text()),
    }
    let start = Instant::now();
    while on && vcam_registered_path().is_none() && start.elapsed() < APPEAR_TIMEOUT {
        std::thread::sleep(Duration::from_millis(250));
    }
    Ok(())
}

/// Updates the extension when the app came with a newer one. Activating an extension that is
/// already active in the same version does nothing, and a replacement needs no approval.
pub fn refresh_camera() {
    if vcam_registered_path().is_some() {
        std::thread::spawn(|| {
            if let Err(e) = set_camera_registered(true) {
                log::warn!("updating the camera extension: {e}");
            }
        });
    }
}

/// The window has a system material behind the page, as Mica on Windows 11: Liquid Glass on
/// macOS 26 and later, the window vibrancy material before (tauri.macos.conf.json).
pub fn mica() -> bool {
    true
}

fn command_output(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !text.is_empty()).then_some(text)
}

/// e.g. `macOS 15.1 (24B83)`.
pub fn os_name() -> String {
    let version = command_output("sw_vers", &["-productVersion"]).unwrap_or_else(|| "?".into());
    match command_output("sw_vers", &["-buildVersion"]) {
        Some(build) => format!("macOS {version} ({build})"),
        None => format!("macOS {version}"),
    }
}

/// The chip, e.g. `Apple M3 Pro`: on Apple silicon the GPU and the video decoder are in it.
pub fn gpu_names() -> Vec<String> {
    command_output("sysctl", &["-n", "machdep.cpu.brand_string"]).into_iter().collect()
}

/// The user's Downloads folder.
pub fn downloads_dir() -> Option<PathBuf> {
    let dir = PathBuf::from(std::env::var_os("HOME")?).join("Downloads");
    dir.is_dir().then_some(dir)
}

/// Opens a link in the default browser, or a folder in the Finder.
pub fn open(target: &str) -> Result<(), String> {
    Command::new("open").arg(target).spawn().map(drop).map_err(|e| e.to_string())
}

/// Shows a file selected in the Finder.
pub fn reveal(path: &Path) {
    let _ = Command::new("open").arg("-R").arg(path).spawn();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_macos() {
        assert!(os_name().starts_with("macOS 1") || os_name().starts_with("macOS 2"), "{}", os_name());
        assert!(!gpu_names().is_empty());
    }

    #[test]
    fn finds_downloads() {
        assert!(downloads_dir().is_some_and(|d| d.is_dir()));
    }
}
