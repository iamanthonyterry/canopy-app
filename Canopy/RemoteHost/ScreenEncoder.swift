import CoreMedia
import Foundation
import ScreenCaptureKit
import VideoToolbox

/// Captures the main display with ScreenCaptureKit and encodes it to low-latency HEVC.
nonisolated final class ScreenEncoder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// HEVC parameter sets, sent before the first frame and again on every keyframe.
    var onConfig: (@Sendable (Data) -> Void)?
    /// (isKeyframe, AVCC sample bytes)
    var onFrame: (@Sendable (Bool, Data) -> Void)?

    private let queue = DispatchQueue(label: "canopy.remote.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var session: VTCompressionSession?
    private var lastBuffer: CVPixelBuffer?
    private var forceKey = false
    private(set) var size = CGSize.zero

    /// Starts capture and returns the encoded size.
    func start() async throws -> CGSize {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first
        else { throw CocoaError(.fileNoSuchFile) }

        // Native pixels, capped at 2560 wide, even dimensions (HEVC wants them).
        let scale = min(1.0, 2560.0 / Double(display.width * 2))
        let w = (Int(Double(display.width * 2) * scale) / 2) * 2
        let h = (Int(Double(display.height * 2) * scale) / 2) * 2
        size = CGSize(width: w, height: h)

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h),
                                                codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard status == noErr, let s else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(s, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_HEVC_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, 14_000_000 as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(s)
        lock.withLock { session = s }

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.queueDepth = 3
        config.showsCursor = true
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        lock.withLock { self.stream = stream }
        return size
    }

    func stop() {
        let (st, se): (SCStream?, VTCompressionSession?) = lock.withLock {
            defer { stream = nil; session = nil; lastBuffer = nil }
            return (stream, session)
        }
        if let st { nonisolated(unsafe) let stream = st; Task { try? await stream.stopCapture() } }
        if let se { VTCompressionSessionInvalidate(se) }
    }

    /// Makes the next frame a keyframe, re-encoding the last picture so a new viewer sees something at once
    /// even if the screen is static.
    func requestKeyframe() {
        queue.async { [self] in
            let buf: CVPixelBuffer? = lock.withLock { forceKey = true; return lastBuffer }
            if let buf { encode(buf, time: CMClockGetTime(CMClockGetHostTimeClock())) }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let buf = sb.imageBuffer else { return }
        // Only encode frames that carry new pixels.
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) != .complete { return }
        lock.withLock { lastBuffer = buf }
        encode(buf, time: sb.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}

    // MARK: Encoding

    private func encode(_ buf: CVPixelBuffer, time: CMTime) {
        let (s, force): (VTCompressionSession?, Bool) = lock.withLock {
            defer { forceKey = false }
            return (session, forceKey)
        }
        guard let s else { return }
        let props: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(s, imageBuffer: buf, presentationTimeStamp: time, duration: .invalid,
                                        frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.handle(sample)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        guard let block = sample.dataBuffer else { return }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKey = !((atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)

        if isKey, let fd = sample.formatDescription {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            var cfg = Data()
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var len = 0
                guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                                                                         parameterSetSizeOut: &len, parameterSetCountOut: nil,
                                                                         nalUnitHeaderLengthOut: nil) == noErr, let ptr else { continue }
                var l = UInt16(len).bigEndian
                withUnsafeBytes(of: &l) { cfg.append(contentsOf: $0) }
                cfg.append(ptr, count: len)
            }
            onConfig?(cfg)
        }

        var length = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &ptr) == kCMBlockBufferNoErr, let ptr else { return }
        onFrame?(isKey, Data(bytes: ptr, count: length))
    }
}
