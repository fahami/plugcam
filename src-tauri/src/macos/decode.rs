//! H.264 → NV12 with VideoToolbox, the decoder built into macOS (`macos/host/decode.m`). It
//! decodes in real-time mode on the Mac's media engine, and every access unit comes out before
//! `decode` returns.

use std::ffi::c_void;

use crate::frame::{ColorInfo, Nv12Frame};
use crate::macos::{self, PcFrame};

#[derive(Debug, thiserror::Error)]
pub enum DecodeError {
    #[error("VideoToolbox: OSStatus {0}")]
    VideoToolbox(i32),
    #[error("cannot create the VideoToolbox decoder")]
    Create,
}

pub struct H264Decoder {
    handle: *mut macos::PcDecoder,
}

// The decoder is used from one thread at a time; VideoToolbox sessions have no thread affinity.
unsafe impl Send for H264Decoder {}

impl H264Decoder {
    /// The size comes from SPS/PPS in the stream; the arguments are only there to match the
    /// Windows decoder.
    pub fn new(_width: u32, _height: u32) -> Result<Self, DecodeError> {
        let handle = unsafe { macos::pc_decoder_new() };
        if handle.is_null() {
            return Err(DecodeError::Create);
        }
        Ok(Self { handle })
    }

    /// True when pictures are decoded in hardware (known after the first SPS/PPS).
    pub fn is_hardware(&self) -> bool {
        unsafe { macos::pc_decoder_is_hardware(self.handle) }
    }

    /// Feeds one Annex B access unit (a frame, or SPS/PPS) and calls `on_frame` for every
    /// picture that comes out.
    pub fn decode(&mut self, data: &[u8], pts_us: u64, on_frame: &mut dyn FnMut(&Nv12Frame)) -> Result<(), DecodeError> {
        let mut callback: &mut dyn FnMut(&Nv12Frame) = on_frame;
        let context = &mut callback as *mut &mut dyn FnMut(&Nv12Frame) as *mut c_void;
        let status = unsafe { macos::pc_decoder_decode(self.handle, data.as_ptr(), data.len(), pts_us, trampoline, context) };
        if status != 0 { Err(DecodeError::VideoToolbox(status)) } else { Ok(()) }
    }
}

unsafe extern "C" fn trampoline(context: *mut c_void, frame: *const PcFrame) {
    // SAFETY: `decode` passes a pointer to its callback, alive for the duration of the call, and
    // the frame's planes are valid until this returns.
    unsafe {
        let callback = &mut *(context as *mut &mut dyn FnMut(&Nv12Frame));
        let f = &*frame;
        callback(&Nv12Frame {
            width: f.width,
            height: f.height,
            y: std::slice::from_raw_parts(f.y, f.y_len),
            y_stride: f.y_stride,
            uv: std::slice::from_raw_parts(f.uv, f.uv_len),
            uv_stride: f.uv_stride,
            color: ColorInfo { full_range: f.full_range, bt709: f.bt709 },
        });
    }
}

impl Drop for H264Decoder {
    fn drop(&mut self) {
        unsafe { macos::pc_decoder_free(self.handle) }
    }
}
