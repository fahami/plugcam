// "Plugcam Camera" for macOS: a CoreMediaIO camera extension.
//
// The device has two streams. Video apps read the source stream like any webcam; the Plugcam
// app writes the phone's picture into the sink stream (macos/host/camera.m). Frames go from one
// to the other as they come, scaled when an app picked another size than the app sends. While
// nothing comes in (camera off in Plugcam, phone reconnecting), apps keep getting the last
// picture, or black before the first one.

import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import VideoToolbox
import os.log

let log = Logger(subsystem: "io.github.plugcam.camera", category: "camera")

/// Must match `PC_CAMERA_UID` in macos/host/plugcam_mac.h.
let deviceID = UUID(uuidString: "FB62D2CA-1CD1-44BF-92BB-51BEEC272B29")!
let sourceID = UUID(uuidString: "458E6976-2C74-4FB3-9AA8-F6FC60C9F89C")!
let sinkID = UUID(uuidString: "13FC76AB-3EE4-4D15-BC67-89B5081FCFDC")!

/// Device property that reads "1" while some app has the camera running. Must match
/// `kClientsSelector` ('plcl') in macos/host/camera.m.
let clientsProperty = CMIOExtensionProperty(rawValue: "4cc_plcl_glob_0000")

func clientsState(_ running: Bool) -> CMIOExtensionPropertyState<AnyObject> {
    CMIOExtensionPropertyState(value: (running ? "1" : "0") as NSString)
}

/// The sizes Plugcam sends (`VCAM_SIZES` in src-tauri/src/settings.rs); 1080p unless an app
/// asks for another.
let sizes: [(Int32, Int32)] = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]
let defaultFormat = 1
let frameDurations = [CMTime(value: 1, timescale: 30), CMTime(value: 1, timescale: 60)]
/// Without a new frame for this long, the last one is repeated so apps keep running.
let repeatAfterNs: UInt64 = 200_000_000

func hostTimeNs() -> UInt64 {
    UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * Double(NSEC_PER_SEC))
}

func makeFormats() -> [CMIOExtensionStreamFormat] {
    sizes.map { width, height in
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: width, height: height,
            extensions: nil, formatDescriptionOut: &description)
        return CMIOExtensionStreamFormat(
            formatDescription: description!, maxFrameDuration: frameDurations[0],
            minFrameDuration: frameDurations[1], validFrameDurations: frameDurations)
    }
}

// MARK: - Device

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStream!
    private var sink: SinkStream!

    /// Everything below is touched on this queue only.
    private let queue = DispatchQueue(label: "io.github.plugcam.camera.frames")
    private var timer: DispatchSourceTimer?
    private var sourceRunning = false
    /// The last picture from the app, at the app's size.
    private var lastInput: CVPixelBuffer?
    private var lastArrival: UInt64 = 0
    /// `lastInput` at the size apps get, made when the two differ.
    private var scaled: CVPixelBuffer?
    private var pool: CVPixelBufferPool?
    private var poolSize = (Int32(0), Int32(0))
    private var transfer: VTPixelTransferSession?

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)
        source = SourceStream(device: self)
        sink = SinkStream(device: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("adding the streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, clientsProperty]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            result.model = "Plugcam Camera"
        }
        if properties.contains(clientsProperty) {
            let running = queue.sync { sourceRunning }
            result.setPropertyState(clientsState(running), forProperty: clientsProperty)
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Source side: what video apps get

    func startSource() {
        queue.sync {
            sourceRunning = true
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in self?.repeatIfIdle() }
            timer.resume()
            self.timer = timer
        }
        notifyClients(true)
        log.info("an app started the camera")
    }

    func stopSource() {
        queue.sync {
            sourceRunning = false
            timer?.cancel()
            timer = nil
        }
        notifyClients(false)
        log.info("the camera is no longer in use")
    }

    private func notifyClients(_ running: Bool) {
        device.notifyPropertiesChanged([clientsProperty: clientsState(running)])
    }

    /// From the sink: a new picture from the Plugcam app.
    func receive(_ buffer: CMSampleBuffer) {
        guard let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        queue.async { [self] in
            lastInput = pixels
            scaled = nil
            lastArrival = hostTimeNs()
            if sourceRunning { send(output()) }
        }
    }

    private func repeatIfIdle() {
        guard sourceRunning, hostTimeNs() - lastArrival > repeatAfterNs else { return }
        send(output())
    }

    /// The last picture at the size of the active format, or black.
    private func output() -> CVPixelBuffer? {
        let (width, height) = sizes[source.activeFormatIndex]
        guard let input = lastInput else { return black(width, height) }
        if CVPixelBufferGetWidth(input) == Int(width) && CVPixelBufferGetHeight(input) == Int(height) {
            return input
        }
        if let scaled, CVPixelBufferGetWidth(scaled) == Int(width) {
            return scaled
        }
        guard let out = newBuffer(width, height) else { return nil }
        if transfer == nil {
            VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transfer)
            if let transfer {
                VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            }
        }
        guard let transfer, VTPixelTransferSessionTransferImage(transfer, from: input, to: out) == noErr else { return nil }
        scaled = out
        return out
    }

    private func black(_ width: Int32, _ height: Int32) -> CVPixelBuffer? {
        if let scaled, CVPixelBufferGetWidth(scaled) == Int(width) {
            return scaled
        }
        guard let out = newBuffer(width, height) else { return nil }
        CVPixelBufferLockBaseAddress(out, [])
        if let base = CVPixelBufferGetBaseAddress(out) {
            let stride = CVPixelBufferGetBytesPerRow(out)
            for row in 0..<Int(height) {
                // BGRA: black, opaque.
                let pixels = (base + row * stride).bindMemory(to: UInt32.self, capacity: Int(width))
                pixels.update(repeating: UInt32(0xFF00_0000).littleEndian, count: Int(width))
            }
        }
        CVPixelBufferUnlockBaseAddress(out, [])
        scaled = out
        return out
    }

    private func newBuffer(_ width: Int32, _ height: Int32) -> CVPixelBuffer? {
        if pool == nil || poolSize != (width, height) {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            poolSize = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func send(_ pixels: CVPixelBuffer?) {
        guard let pixels else { return }
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format)
        guard let format else { return }
        let now = hostTimeNs()
        var timing = CMSampleTimingInfo(
            duration: frameDurations[0], presentationTimeStamp: CMTime(value: CMTimeValue(now), timescale: CMTimeScale(NSEC_PER_SEC)),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample)
        if let sample {
            source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now)
        }
    }
}

// MARK: - Streams

/// What video apps read.
final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource
    let formats = makeFormats()
    private let lock = NSLock()
    private var activeFormat = defaultFormat

    init(device: DeviceSource) {
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "Plugcam Camera", streamID: sourceID, direction: .source, clockType: .hostTime, source: self)
    }

    var activeFormatIndex: Int {
        lock.withLock { activeFormat }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = frameDurations[0]
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex, formats.indices.contains(index) {
            lock.withLock { activeFormat = index }
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        device.startSource()
    }

    func stopStream() throws {
        device.stopSource()
    }
}

/// What the Plugcam app writes into.
final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private unowned let device: DeviceSource
    let formats = makeFormats()
    private var client: CMIOExtensionClient?
    private var running = false

    init(device: DeviceSource) {
        self.device = device
        super.init()
        stream = CMIOExtensionStream(
            localizedName: "Plugcam Camera input", streamID: sinkID, direction: .sink, clockType: .hostTime, source: self)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData,
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = defaultFormat
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = frameDurations[0]
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            result.sinkBufferQueueSize = 2
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            result.sinkBuffersRequiredForStartup = 1
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        running = true
        log.info("Plugcam started sending")
        consume()
    }

    func stopStream() throws {
        running = false
        log.info("Plugcam stopped sending")
    }

    private func consume() {
        guard running, let client else { return }
        stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, _ in
            guard let self else { return }
            if let buffer {
                self.device.receive(buffer)
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: hostTimeNs())
                self.stream.notifyScheduledOutputChanged(output)
            }
            // Without a buffer (none queued yet, or an error), ask again a moment later.
            if buffer == nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { self.consume() }
            } else {
                self.consume()
            }
        }
    }
}

// MARK: - Provider

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "Plugcam Camera")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("adding the device: \(error.localizedDescription)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            result.manufacturer = "Plugcam"
        }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
