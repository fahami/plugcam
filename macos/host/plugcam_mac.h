// The C interface between the Rust app and its macOS backend (decode.m, camera.m). Declared
// again on the Rust side in src-tauri/src/macos/mod.rs; keep the two in step.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// UID of the "Plugcam Camera" device. Must match `deviceID` in macos/CameraExtension/Provider.swift.
#define PC_CAMERA_UID "FB62D2CA-1CD1-44BF-92BB-51BEEC272B29"

// ---- H.264 decoder (VideoToolbox) -------------------------------------------------------------

// One decoded picture, NV12, valid only during the callback.
typedef struct {
    uint32_t width, height;
    const uint8_t *y;
    uint32_t y_stride;
    const uint8_t *uv;
    uint32_t uv_stride;
    size_t y_len, uv_len;
    bool full_range;
    bool bt709;
} PcFrame;

typedef void (*PcFrameCallback)(void *context, const PcFrame *frame);

typedef struct PcDecoder PcDecoder;

PcDecoder *pc_decoder_new(void);
// Feeds one Annex B access unit (a frame, or SPS/PPS); `on_frame` runs for each picture before
// this returns. Returns 0 or an OSStatus.
int32_t pc_decoder_decode(PcDecoder *d, const uint8_t *data, size_t len, uint64_t pts_us, PcFrameCallback on_frame,
                          void *context);
// True once a session exists and VideoToolbox reports a hardware decoder for it.
bool pc_decoder_is_hardware(const PcDecoder *d);
void pc_decoder_free(PcDecoder *d);

// ---- Virtual camera (client of the CoreMediaIO camera extension) ------------------------------

typedef struct PcCamera PcCamera;

// True when the extension is active, i.e. the system lists the "Plugcam Camera" device.
bool pc_camera_present(void);
// Opens the extension's sink stream for frames of `width`x`height`. NULL if the device is not
// there or its sink cannot be started; `error` (if not NULL) gets a message.
PcCamera *pc_camera_open(uint32_t width, uint32_t height, char *error, size_t error_len);
// Publishes one 24-bit BGR frame, rows top to bottom, no padding.
void pc_camera_send(PcCamera *c, const uint8_t *bgr);
// True while some application has the camera open.
bool pc_camera_is_connected(PcCamera *c);
void pc_camera_close(PcCamera *c);

// Asks macOS to activate (install or update) or deactivate the camera extension bundled in the
// app, and waits up to `timeout_ms` for the answer. When macOS needs the user's approval it opens
// System Settings at the right page. Returns 0 when done, 1 when still waiting for approval at
// the timeout, -1 on error with a message in `error`.
int32_t pc_camera_extension_request(bool activate, uint32_t timeout_ms, char *error, size_t error_len);
