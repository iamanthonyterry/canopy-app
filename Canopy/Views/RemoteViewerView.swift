import AppKit
import AVFoundation
import Combine
import SwiftUI

/// The window that shows another Mac's screen and sends it pointer and keyboard input.
struct RemoteViewerView: View {
    let macID: UUID?
    @StateObject private var holder = SessionHolder()

    var body: some View {
        Group {
            if let session = holder.session {
                ViewerContent(session: session)
            } else {
                Text("This Mac is no longer saved.").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 480, minHeight: 300)
        .navigationTitle(holder.name)
        .onAppear { holder.open(macID) }
        .onDisappear { holder.close() }
    }

    @MainActor
    private final class SessionHolder: ObservableObject {
        @Published var session: RemoteViewerSession?
        @Published var name = "Remote Mac"

        func open(_ id: UUID?) {
            guard session == nil, let id, let mac = RemoteMacStore.shared.mac(id),
                  let code = RemoteMacStore.shared.pairingCode(for: id) else { return }
            name = mac.name
            let s = RemoteViewerSession(pairingCode: code)
            session = s
            s.connect()
        }

        func close() { session?.disconnect(); session = nil }
    }
}

private struct ViewerContent: View {
    @ObservedObject var session: RemoteViewerSession

    var body: some View {
        ZStack {
            Color.black
            RemoteScreenSurface(session: session)
            switch session.status {
            case .connecting, .idle:
                VStack(spacing: 8) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Connecting…").foregroundStyle(.white.opacity(0.8))
                }
            case .failed(let reason):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                    Text(reason).multilineTextAlignment(.center).foregroundStyle(.white).frame(maxWidth: 360)
                    Button("Try Again") { session.reconnect() }
                }
                .padding(24)
            case .connected:
                EmptyView()
            }
        }
    }
}

/// Draws the decoded video and turns Mac mouse and keyboard events into remote input.
private struct RemoteScreenSurface: NSViewRepresentable {
    let session: RemoteViewerSession

    func makeNSView(context: Context) -> ScreenNSView {
        let v = ScreenNSView()
        v.session = session
        session.onSample = { [weak v] sample in v?.show(sample) }
        return v
    }

    func updateNSView(_ v: ScreenNSView, context: Context) {
        v.session = session
        v.remoteSize = session.remoteSize
    }
}

private final class ScreenNSView: NSView {
    weak var session: RemoteViewerSession?
    var remoteSize = CGSize.zero
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var tracking: NSTrackingArea?
    /// The remote screen shows its own pointer, so the local one is hidden over the picture.
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func makeBackingLayer() -> CALayer {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        l.backgroundColor = NSColor.black.cgColor
        return l
    }

    /// macOS 27 queues samples through a receiver on a render synchronizer; macOS 26 still uses the renderer directly.
    private var synchronizer: AnyObject?
    private var receiver: Any?

    func show(_ sample: CMSampleBuffer) {
        if #available(macOS 27, *) { showWithReceiver(sample) } else { showWithRenderer(sample) }
    }

    @available(macOS 27, *)
    private func showWithReceiver(_ sample: CMSampleBuffer) {
        let rx: AVSampleBufferVideoRenderer.Receiver
        if let existing = receiver as? AVSampleBufferVideoRenderer.Receiver {
            rx = existing
        } else {
            let sync = AVSampleBufferRenderSynchronizer()
            rx = sync.sampleBufferReceiver(adding: displayLayer.sampleBufferRenderer)
            // Frames carry host-clock times, so run the synchronizer's clock from now.
            sync.setRate(1, time: CMClockGetTime(CMClockGetHostTimeClock()))
            synchronizer = sync; receiver = rx
        }
        // Each sample is built fresh for one display and never touched again, so handing it over is safe.
        nonisolated(unsafe) let handoff = sample
        switch rx.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: handoff)) {
        case .cancelledDueToFlushRequiredToResume, .cancelledDueToError: rx.flush()   // the next keyframe resumes
        default: break
        }
    }

    @available(macOS, deprecated: 27.0)
    private func showWithRenderer(_ sample: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t); tracking = t
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.blankCursor) }

    // MARK: Pointer

    private func point(_ e: NSEvent, clamp: Bool = false) -> CGPoint? {
        RemoteScreenGeometry.normalized(convert(e.locationInWindow, from: nil), remote: remoteSize, in: bounds, clamp: clamp)
    }

    private func flags(_ e: NSEvent) -> UInt64 { UInt64(e.modifierFlags.rawValue) & 0x1F0000 }

    override func mouseMoved(with e: NSEvent) { if let p = point(e) { session?.pointerMoved(to: p) } }
    override func mouseDragged(with e: NSEvent) { if let p = point(e, clamp: true) { session?.pointerDragged(to: p, right: false) } }
    override func rightMouseDragged(with e: NSEvent) { if let p = point(e, clamp: true) { session?.pointerDragged(to: p, right: true) } }

    override func mouseDown(with e: NSEvent) { down(e, right: false) }
    override func mouseUp(with e: NSEvent) { up(e, right: false) }
    override func rightMouseDown(with e: NSEvent) { down(e, right: true) }
    override func rightMouseUp(with e: NSEvent) { up(e, right: true) }

    private func down(_ e: NSEvent, right: Bool) {
        window?.makeFirstResponder(self)
        guard let p = point(e) else { return }
        session?.pointerDown(at: p, right: right, clickCount: max(e.clickCount, 1), flags: flags(e))
    }

    private func up(_ e: NSEvent, right: Bool) {
        guard let p = point(e, clamp: true) else { return }
        session?.pointerUp(at: p, right: right, clickCount: max(e.clickCount, 1), flags: flags(e))
    }

    override func scrollWheel(with e: NSEvent) {
        let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
        session?.scroll(dx: Double(e.scrollingDeltaX * k), dy: Double(e.scrollingDeltaY * k))
    }

    // MARK: Keyboard

    override func keyDown(with e: NSEvent) { session?.key(e.keyCode, down: true, flags: flags(e)) }
    override func keyUp(with e: NSEvent) { session?.key(e.keyCode, down: false, flags: flags(e)) }

    /// Shortcuts like ⌘Q or ⌘W go to the remote Mac, not to Canopy's menus, while this window has focus.
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, e.type == .keyDown else { return false }
        keyDown(with: e)
        return true
    }

    override func flagsChanged(with e: NSEvent) {
        // Modifier keys arrive as flag changes; the key is down when its flag is now set.
        let mask: UInt64
        switch e.keyCode {
        case 54, 55: mask = 0x100000   // command
        case 56, 60: mask = 0x20000    // shift
        case 58, 61: mask = 0x80000    // option
        case 59, 62: mask = 0x40000    // control
        case 57: mask = 0x10000        // caps lock
        default: return
        }
        let f = flags(e)
        session?.key(e.keyCode, down: f & mask != 0, flags: f)
    }
}
