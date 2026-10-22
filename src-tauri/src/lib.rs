pub mod adb;
pub mod app;
// The platform-specific modules have one file per OS with the same API. On macOS they call the
// Objective-C half in `macos/host` (see build.rs).
#[cfg_attr(target_os = "macos", path = "macos/decode.rs")]
pub mod decode;
pub mod diag;
pub mod frame;
#[cfg(target_os = "macos")]
mod macos;
pub mod pipeline;
#[cfg_attr(target_os = "macos", path = "macos/platform.rs")]
pub mod platform;
#[cfg_attr(target_os = "macos", path = "macos/portable.rs")]
pub mod portable;
pub mod preview;
pub mod resources;
pub mod scrcpy;
pub mod settings;
#[cfg_attr(target_os = "macos", path = "macos/vcam.rs")]
pub mod vcam;
pub mod wifi;
