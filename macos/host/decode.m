// H.264 decoding with VideoToolbox for the Rust app (src-tauri/src/macos/decode.rs).
//
// scrcpy sends Annex B: start codes between NAL units, SPS and PPS in a packet of their own.
// VideoToolbox wants the parameter sets in a format description and the other NAL units with
// 4-byte length prefixes (AVCC), so each access unit is rewritten on the way in. Pictures come out
// as full-range NV12 in system memory, read through the callback before `pc_decoder_decode`
// returns.

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "plugcam_mac.h"

struct PcDecoder {
    VTDecompressionSessionRef session;
    CMVideoFormatDescriptionRef format;
    CFDataRef sps, pps;
    bool hardware;
    // Set for the duration of one `pc_decoder_decode` call.
    PcFrameCallback on_frame;
    void *context;
    OSStatus frame_status;
};

PcDecoder *pc_decoder_new(void) {
    return calloc(1, sizeof(PcDecoder));
}

static void drop_session(PcDecoder *d) {
    if (d->session) {
        VTDecompressionSessionInvalidate(d->session);
        CFRelease(d->session);
        d->session = NULL;
    }
}

void pc_decoder_free(PcDecoder *d) {
    if (!d) return;
    drop_session(d);
    if (d->format) CFRelease(d->format);
    if (d->sps) CFRelease(d->sps);
    if (d->pps) CFRelease(d->pps);
    free(d);
}

bool pc_decoder_is_hardware(const PcDecoder *d) {
    return d->hardware;
}

static void on_output(void *refcon, void *frame_refcon, OSStatus status, VTDecodeInfoFlags flags,
                      CVImageBufferRef image, CMTime pts, CMTime duration) {
    PcDecoder *d = refcon;
    if (status != noErr) {
        d->frame_status = status;
        return;
    }
    if (!image || !d->on_frame || CVPixelBufferGetPlaneCount(image) < 2) return;

    if (CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
    uint32_t width = (uint32_t)CVPixelBufferGetWidth(image);
    uint32_t height = (uint32_t)CVPixelBufferGetHeight(image);
    uint32_t y_stride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(image, 0);
    uint32_t uv_stride = (uint32_t)CVPixelBufferGetBytesPerRowOfPlane(image, 1);
    bool bt709 = false;
    CFTypeRef matrix = CVBufferCopyAttachment(image, kCVImageBufferYCbCrMatrixKey, NULL);
    if (matrix) {
        bt709 = CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
        CFRelease(matrix);
    }
    PcFrame frame = {
        .width = width,
        .height = height,
        .y = CVPixelBufferGetBaseAddressOfPlane(image, 0),
        .y_stride = y_stride,
        .uv = CVPixelBufferGetBaseAddressOfPlane(image, 1),
        .uv_stride = uv_stride,
        // Planes exactly as tall as the picture, like the Windows decoder hands them over.
        .y_len = (size_t)y_stride * height,
        .uv_len = (size_t)uv_stride * ((height + 1) / 2),
        .full_range = CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        .bt709 = bt709,
    };
    if (frame.y && frame.uv) d->on_frame(d->context, &frame);
    CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
}

static OSStatus open_session(PcDecoder *d) {
    drop_session(d);
    NSDictionary *spec = @{(__bridge NSString *)kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder : @YES};
    NSDictionary *attrs = @{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
    };
    VTDecompressionOutputCallbackRecord callback = {on_output, d};
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, d->format, (__bridge CFDictionaryRef)spec,
                                                   (__bridge CFDictionaryRef)attrs, &callback, &d->session);
    if (status != noErr) return status;
    VTSessionSetProperty(d->session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    CFBooleanRef hw = NULL;
    if (VTSessionCopyProperty(d->session, kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              kCFAllocatorDefault, &hw) == noErr &&
        hw) {
        d->hardware = CFBooleanGetValue(hw);
        CFRelease(hw);
    }
    CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(d->format);
    NSLog(@"plugcam: VideoToolbox session %dx%d, %s", dims.width, dims.height, d->hardware ? "hardware" : "software");
    return noErr;
}

// Takes new parameter sets; (re)creates the format description and, if it has to, the session.
static OSStatus set_parameters(PcDecoder *d, const uint8_t *sps, size_t sps_len, const uint8_t *pps, size_t pps_len) {
    bool same = d->sps && d->pps && (size_t)CFDataGetLength(d->sps) == sps_len &&
                (size_t)CFDataGetLength(d->pps) == pps_len && !memcmp(CFDataGetBytePtr(d->sps), sps, sps_len) &&
                !memcmp(CFDataGetBytePtr(d->pps), pps, pps_len);
    if (same && d->session) return noErr;

    const uint8_t *sets[2] = {sps, pps};
    size_t sizes[2] = {sps_len, pps_len};
    CMVideoFormatDescriptionRef format = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &format);
    if (status != noErr) return status;

    if (d->sps) CFRelease(d->sps);
    if (d->pps) CFRelease(d->pps);
    d->sps = CFDataCreate(kCFAllocatorDefault, sps, (CFIndex)sps_len);
    d->pps = CFDataCreate(kCFAllocatorDefault, pps, (CFIndex)pps_len);
    if (d->format) CFRelease(d->format);
    d->format = format;
    if (d->session && VTDecompressionSessionCanAcceptFormatDescription(d->session, format)) return noErr;
    return open_session(d);
}

// Calls `nal` for each NAL unit between Annex B start codes.
static void each_nal(const uint8_t *data, size_t len, void (^nal)(const uint8_t *unit, size_t unit_len)) {
    size_t i = 0, start = SIZE_MAX;
    while (i + 3 <= len) {
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            if (start != SIZE_MAX) {
                size_t end = i;
                while (end > start && data[end - 1] == 0) end--; // trailing zero of a 4-byte start code
                if (end > start) nal(data + start, end - start);
            }
            i += 3;
            start = i;
        } else {
            i++;
        }
    }
    if (start != SIZE_MAX && start < len) nal(data + start, len - start);
}

static OSStatus decode_sample(PcDecoder *d, NSData *avcc, uint64_t pts_us) {
    CMBlockBufferRef block = NULL;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, avcc.length, kCFAllocatorDefault,
                                                         NULL, 0, avcc.length, 0, &block);
    if (status != noErr) return status;
    status = CMBlockBufferReplaceDataBytes(avcc.bytes, block, 0, avcc.length);
    CMSampleBufferRef sample = NULL;
    if (status == noErr) {
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMake((int64_t)pts_us, 1000000), kCMTimeInvalid};
        size_t size = avcc.length;
        status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, d->format, 1, 1, &timing, 1, &size, &sample);
    }
    CFRelease(block);
    if (status != noErr) return status;

    d->frame_status = noErr;
    VTDecodeInfoFlags info = 0;
    status = VTDecompressionSessionDecodeFrame(d->session, sample, 0, NULL, &info);
    if (status == noErr) VTDecompressionSessionWaitForAsynchronousFrames(d->session);
    CFRelease(sample);
    return status != noErr ? status : d->frame_status;
}

int32_t pc_decoder_decode(PcDecoder *d, const uint8_t *data, size_t len, uint64_t pts_us, PcFrameCallback on_frame,
                          void *context) {
    @autoreleasepool {
        __block const uint8_t *sps = NULL, *pps = NULL;
        __block size_t sps_len = 0, pps_len = 0;
        NSMutableData *avcc = [NSMutableData dataWithCapacity:len + 16];
        each_nal(data, len, ^(const uint8_t *unit, size_t unit_len) {
            switch (unit[0] & 0x1f) {
            case 7:
                sps = unit, sps_len = unit_len;
                break;
            case 8:
                pps = unit, pps_len = unit_len;
                break;
            case 9: // access unit delimiter
                break;
            default: {
                uint32_t be = CFSwapInt32HostToBig((uint32_t)unit_len);
                [avcc appendBytes:&be length:4];
                [avcc appendBytes:unit length:unit_len];
            }
            }
        });

        OSStatus status = noErr;
        if (sps || pps) {
            // A packet may carry only one of the two; the other is the one seen last.
            if (!sps && d->sps) sps = CFDataGetBytePtr(d->sps), sps_len = (size_t)CFDataGetLength(d->sps);
            if (!pps && d->pps) pps = CFDataGetBytePtr(d->pps), pps_len = (size_t)CFDataGetLength(d->pps);
            if (sps && pps) status = set_parameters(d, sps, sps_len, pps, pps_len);
            if (status != noErr) return status;
        }
        if (avcc.length == 0 || !d->session) return noErr; // nothing to show before SPS/PPS

        d->on_frame = on_frame;
        d->context = context;
        status = decode_sample(d, avcc, pts_us);
        if (status == kVTInvalidSessionErr) {
            // The media engine went away (sleep, GPU switch): start over with the same format.
            status = open_session(d);
            if (status == noErr) status = decode_sample(d, avcc, pts_us);
        }
        d->on_frame = NULL;
        d->context = NULL;
        return status;
    }
}
