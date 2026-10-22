//! "Plugcam Camera" on macOS: a CoreMediaIO camera extension (`macos/CameraExtension`) that
//! macOS runs once it is installed. This module feeds it frames through its sink stream
//! (`macos/host/camera.m`); `platform::set_camera_registered` installs it.

use crate::macos::{self, ErrorText};

#[derive(Debug, thiserror::Error)]
pub enum VcamError {
    #[error("width and height must be positive multiples of 4, got {0}x{1}")]
    BadSize(u32, u32),
    #[error("{0}")]
    Open(String),
}

/// A live virtual camera. Frames are 24-bit BGR, rows top to bottom, no padding.
/// Apps keep seeing the last picture when this is dropped, as with no app sending.
pub struct VirtualCamera {
    handle: *mut macos::PcCamera,
    width: u32,
    height: u32,
}

// The camera is only ever used from one thread at a time.
unsafe impl Send for VirtualCamera {}

/// The camera of this platform, `width`x`height`.
pub fn open(width: u32, height: u32) -> Result<VirtualCamera, String> {
    VirtualCamera::create(width, height).map_err(|e| e.to_string())
}

impl VirtualCamera {
    pub fn create(width: u32, height: u32) -> Result<Self, VcamError> {
        if width == 0 || height == 0 || width % 4 != 0 || height % 4 != 0 {
            return Err(VcamError::BadSize(width, height));
        }
        let mut error = ErrorText::new();
        let handle = unsafe { macos::pc_camera_open(width, height, error.ptr(), error.len()) };
        if handle.is_null() {
            return Err(VcamError::Open(error.text()));
        }
        Ok(Self { handle, width, height })
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }

    /// Byte length `send_frame` expects.
    pub fn frame_len(&self) -> usize {
        self.width as usize * self.height as usize * 3
    }

    /// Publishes one BGR frame. Panics if the buffer size does not match the camera.
    pub fn send_frame(&self, bgr: &[u8]) {
        assert_eq!(bgr.len(), self.frame_len(), "frame size does not match the camera");
        unsafe { macos::pc_camera_send(self.handle, bgr.as_ptr()) }
    }

    /// True while some application has the camera open.
    pub fn is_connected(&self) -> bool {
        unsafe { macos::pc_camera_is_connected(self.handle) }
    }
}

impl Drop for VirtualCamera {
    fn drop(&mut self) {
        unsafe { macos::pc_camera_close(self.handle) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_sizes_the_camera_cannot_handle() {
        for (w, h) in [(0, 1080), (1920, 0), (1922, 1080), (1920, 1082)] {
            let err = VirtualCamera::create(w, h).err().unwrap();
            assert!(matches!(err, VcamError::BadSize(..)), "{w}x{h}: {err}");
        }
    }
}
