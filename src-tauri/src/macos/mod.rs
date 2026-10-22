//! The C interface of the Objective-C half in `macos/host` (declared in `plugcam_mac.h`).

use std::ffi::{c_char, c_void};

#[repr(C)]
pub struct PcFrame {
    pub width: u32,
    pub height: u32,
    pub y: *const u8,
    pub y_stride: u32,
    pub uv: *const u8,
    pub uv_stride: u32,
    pub y_len: usize,
    pub uv_len: usize,
    pub full_range: bool,
    pub bt709: bool,
}

pub type PcFrameCallback = unsafe extern "C" fn(context: *mut c_void, frame: *const PcFrame);

#[repr(C)]
pub struct PcDecoder {
    _private: [u8; 0],
}

#[repr(C)]
pub struct PcCamera {
    _private: [u8; 0],
}

unsafe extern "C" {
    pub fn pc_decoder_new() -> *mut PcDecoder;
    pub fn pc_decoder_decode(
        d: *mut PcDecoder,
        data: *const u8,
        len: usize,
        pts_us: u64,
        on_frame: PcFrameCallback,
        context: *mut c_void,
    ) -> i32;
    pub fn pc_decoder_is_hardware(d: *const PcDecoder) -> bool;
    pub fn pc_decoder_free(d: *mut PcDecoder);

    pub fn pc_camera_present() -> bool;
    pub fn pc_camera_open(width: u32, height: u32, error: *mut c_char, error_len: usize) -> *mut PcCamera;
    pub fn pc_camera_send(c: *mut PcCamera, bgr: *const u8);
    pub fn pc_camera_is_connected(c: *mut PcCamera) -> bool;
    pub fn pc_camera_close(c: *mut PcCamera);
    pub fn pc_camera_extension_request(activate: bool, timeout_ms: u32, error: *mut c_char, error_len: usize) -> i32;
}

/// A buffer for the `error` out-parameters, read back as a string.
pub struct ErrorText([u8; 512]);

impl ErrorText {
    pub fn new() -> Self {
        Self([0; 512])
    }

    pub fn ptr(&mut self) -> *mut c_char {
        self.0.as_mut_ptr().cast()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn text(&self) -> String {
        let end = self.0.iter().position(|&b| b == 0).unwrap_or(self.0.len());
        String::from_utf8_lossy(&self.0[..end]).into_owned()
    }
}
