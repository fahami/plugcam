// The app's side of "Plugcam Camera" on macOS (src-tauri/src/macos/vcam.rs).
//
// The camera itself is a CoreMediaIO camera extension (macos/CameraExtension) that macOS runs
// on its own. It has two streams: the source that video apps read, and a sink that this app
// writes into. Frames travel as IOSurface-backed pixel buffers, so they cross into the extension
// without a copy. This file also asks macOS to install the extension bundled in the app.

#import <Accelerate/Accelerate.h>
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <SystemExtensions/SystemExtensions.h>

#include "plugcam_mac.h"

// Device property the extension sets to "1" while some app reads the camera. Must match
// `clientsProperty` in macos/CameraExtension/Provider.swift.
static const CMIOObjectPropertySelector kClientsSelector = 'plcl';

static void set_error(char *error, size_t error_len, NSString *message) {
    if (error && error_len) snprintf(error, error_len, "%s", message.UTF8String ?: "");
}

static CMIOObjectPropertyAddress global_address(CMIOObjectPropertySelector selector) {
    return (CMIOObjectPropertyAddress){selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
}

// The object IDs a list property holds (devices of the system, streams of a device).
static NSArray<NSNumber *> *object_list(CMIOObjectID object, CMIOObjectPropertySelector selector) {
    CMIOObjectPropertyAddress addr = global_address(selector);
    UInt32 size = 0;
    if (CMIOObjectGetPropertyDataSize(object, &addr, 0, NULL, &size) != kCMIOHardwareNoError || size == 0) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(object, &addr, 0, NULL, size, &used, data.mutableBytes) != kCMIOHardwareNoError) return @[];
    NSMutableArray *ids = [NSMutableArray array];
    const CMIOObjectID *items = data.bytes;
    for (UInt32 i = 0; i < used / sizeof(CMIOObjectID); i++) [ids addObject:@(items[i])];
    return ids;
}

static CMIODeviceID find_device(void) {
    for (NSNumber *device in object_list(kCMIOObjectSystemObject, kCMIOHardwarePropertyDevices)) {
        CMIOObjectPropertyAddress addr = global_address(kCMIODevicePropertyDeviceUID);
        CFStringRef uid = NULL;
        UInt32 used = 0;
        if (CMIOObjectGetPropertyData(device.unsignedIntValue, &addr, 0, NULL, sizeof uid, &used, &uid) != kCMIOHardwareNoError || !uid)
            continue;
        bool match = CFStringCompare(uid, CFSTR(PC_CAMERA_UID), kCFCompareCaseInsensitive) == kCFCompareEqualTo;
        CFRelease(uid);
        if (match) return device.unsignedIntValue;
    }
    return kCMIOObjectUnknown;
}

bool pc_camera_present(void) {
    @autoreleasepool {
        return find_device() != kCMIOObjectUnknown;
    }
}

struct PcCamera {
    CMIODeviceID device;
    CMIOStreamID sink;
    CMSimpleQueueRef queue;
    CVPixelBufferPoolRef pool;
    CMVideoFormatDescriptionRef format;
    uint32_t width, height;
};

static void queue_altered(CMIOStreamID stream, void *token, void *refcon) {
    // The extension took a buffer; nothing to do, `pc_camera_send` checks for room itself.
}

void pc_camera_close(PcCamera *c) {
    if (!c) return;
    if (c->sink != kCMIOObjectUnknown) CMIODeviceStopStream(c->device, c->sink);
    if (c->queue) CFRelease(c->queue);
    if (c->pool) CVPixelBufferPoolRelease(c->pool);
    if (c->format) CFRelease(c->format);
    free(c);
}

PcCamera *pc_camera_open(uint32_t width, uint32_t height, char *error, size_t error_len) {
    @autoreleasepool {
        CMIODeviceID device = find_device();
        if (device == kCMIOObjectUnknown) {
            set_error(error, error_len, @"Plugcam Camera is not installed (camera extension not active)");
            return NULL;
        }
        // The extension has a source stream and a sink. CMIO directions are the device's view: the
        // source delivers video into the computer (1, input), the sink takes it out (0, output).
        CMIOStreamID sink = kCMIOObjectUnknown;
        for (NSNumber *stream in object_list(device, kCMIODevicePropertyStreams)) {
            CMIOObjectPropertyAddress addr = global_address(kCMIOStreamPropertyDirection);
            UInt32 direction = 0, used = 0;
            if (CMIOObjectGetPropertyData(stream.unsignedIntValue, &addr, 0, NULL, sizeof direction, &used, &direction) ==
                    kCMIOHardwareNoError &&
                direction == 0) {
                sink = stream.unsignedIntValue;
            }
        }
        if (sink == kCMIOObjectUnknown) {
            set_error(error, error_len, @"the camera extension has no sink stream (an older version still running?)");
            return NULL;
        }

        PcCamera *c = calloc(1, sizeof(PcCamera));
        c->device = device;
        c->width = width;
        c->height = height;
        OSStatus status = CMIOStreamCopyBufferQueue(sink, queue_altered, c, &c->queue);
        if (status != kCMIOHardwareNoError || !c->queue) {
            set_error(error, error_len, [NSString stringWithFormat:@"CMIOStreamCopyBufferQueue failed (%d)", (int)status]);
            pc_camera_close(c);
            return NULL;
        }
        status = CMIODeviceStartStream(device, sink);
        if (status != kCMIOHardwareNoError) {
            set_error(error, error_len, [NSString stringWithFormat:@"CMIODeviceStartStream failed (%d)", (int)status]);
            pc_camera_close(c);
            return NULL;
        }
        c->sink = sink;

        NSDictionary *attrs = @{
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (__bridge NSString *)kCVPixelBufferWidthKey : @(width),
            (__bridge NSString *)kCVPixelBufferHeightKey : @(height),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
        };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attrs, &c->pool) != kCVReturnSuccess) {
            set_error(error, error_len, @"cannot create the pixel buffer pool");
            pc_camera_close(c);
            return NULL;
        }
        return c;
    }
}

void pc_camera_send(PcCamera *c, const uint8_t *bgr) {
    // A full queue means the extension is behind (or gone): drop this frame rather than wait.
    if (CMSimpleQueueGetCount(c->queue) >= CMSimpleQueueGetCapacity(c->queue)) return;

    CVPixelBufferRef pixels = NULL;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, c->pool, &pixels) != kCVReturnSuccess) return;
    CVPixelBufferLockBaseAddress(pixels, 0);
    // B, G, R read as "R, G, B" come out as B, G, R, A: the BGRA the buffer holds.
    vImage_Buffer src = {(void *)bgr, c->height, c->width, (size_t)c->width * 3};
    vImage_Buffer dst = {CVPixelBufferGetBaseAddress(pixels), c->height, c->width, CVPixelBufferGetBytesPerRow(pixels)};
    vImageConvert_RGB888toRGBA8888(&src, NULL, 255, &dst, false, kvImageNoFlags);
    CVPixelBufferUnlockBaseAddress(pixels, 0);

    if (!c->format || !CMVideoFormatDescriptionMatchesImageBuffer(c->format, pixels)) {
        if (c->format) CFRelease(c->format);
        c->format = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixels, &c->format);
    }
    CMSampleBufferRef sample = NULL;
    if (c->format) {
        CMSampleTimingInfo timing = {kCMTimeInvalid, CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixels, c->format, &timing, &sample);
    }
    CVPixelBufferRelease(pixels);
    // On success the queue owns the reference; the extension releases it.
    if (sample && CMSimpleQueueEnqueue(c->queue, sample) != noErr) CFRelease(sample);
}

bool pc_camera_is_connected(PcCamera *c) {
    CMIOObjectPropertyAddress addr = global_address(kClientsSelector);
    if (!CMIOObjectHasProperty(c->device, &addr)) return false;
    CFTypeRef value = NULL;
    UInt32 used = 0;
    if (CMIOObjectGetPropertyData(c->device, &addr, 0, NULL, sizeof value, &used, &value) != kCMIOHardwareNoError || !value)
        return false;
    bool connected = CFGetTypeID(value) == CFStringGetTypeID() && CFStringCompare(value, CFSTR("1"), 0) == kCFCompareEqualTo;
    CFRelease(value);
    return connected;
}

// ---- Installing the extension -----------------------------------------------------------------

@interface PcExtensionRequest : NSObject <OSSystemExtensionRequestDelegate>
@property(nonatomic) dispatch_semaphore_t done;
@property(nonatomic, copy) NSString *error;
@end

@implementation PcExtensionRequest

- (OSSystemExtensionReplacementAction)request:(OSSystemExtensionRequest *)request
                  actionForReplacingExtension:(OSSystemExtensionProperties *)existing
                                withExtension:(OSSystemExtensionProperties *)extension {
    NSLog(@"plugcam: replacing camera extension %@ with %@", existing.bundleShortVersion, extension.bundleShortVersion);
    return OSSystemExtensionReplacementActionReplace;
}

- (void)requestNeedsUserApproval:(OSSystemExtensionRequest *)request {
    NSLog(@"plugcam: camera extension waits for approval in System Settings");
    dispatch_async(dispatch_get_main_queue(), ^{
      NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.LoginItems-Settings.extension"];
      [NSWorkspace.sharedWorkspace openURL:url];
    });
}

- (void)request:(OSSystemExtensionRequest *)request didFinishWithResult:(OSSystemExtensionRequestResult)result {
    NSLog(@"plugcam: camera extension request finished (%ld)", (long)result);
    dispatch_semaphore_signal(self.done);
}

- (void)request:(OSSystemExtensionRequest *)request didFailWithError:(NSError *)error {
    NSLog(@"plugcam: camera extension request failed: %@", error);
    self.error = error.localizedDescription ?: @"unknown error";
    dispatch_semaphore_signal(self.done);
}

@end

int32_t pc_camera_extension_request(bool activate, uint32_t timeout_ms, char *error, size_t error_len) {
    // Delegates must live until macOS answers, which can be long after a timeout here.
    static NSMutableSet *pending;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      pending = [NSMutableSet set];
    });

    @autoreleasepool {
        NSString *app = NSBundle.mainBundle.bundleIdentifier;
        if (!app || ![NSBundle.mainBundle.bundlePath hasSuffix:@".app"]) {
            set_error(error, error_len, @"Plugcam is not running from its app bundle");
            return -1;
        }
        NSString *identifier = [app stringByAppendingString:@".camera"];
        dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        OSSystemExtensionRequest *request =
            activate ? [OSSystemExtensionRequest activationRequestForExtension:identifier queue:queue]
                     : [OSSystemExtensionRequest deactivationRequestForExtension:identifier queue:queue];
        PcExtensionRequest *delegate = [PcExtensionRequest new];
        delegate.done = dispatch_semaphore_create(0);
        request.delegate = delegate;
        @synchronized(pending) {
            [pending addObject:delegate];
        }
        [OSSystemExtensionManager.sharedManager submitRequest:request];

        long waited = dispatch_semaphore_wait(delegate.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)timeout_ms * NSEC_PER_MSEC));
        if (waited != 0) return 1;
        @synchronized(pending) {
            [pending removeObject:delegate];
        }
        if (delegate.error) {
            set_error(error, error_len, delegate.error);
            return -1;
        }
        return 0;
    }
}
