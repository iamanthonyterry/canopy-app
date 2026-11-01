import CoreGraphics
import Foundation
import Testing
@testable import Canopy

struct RemotePairingCodeTests {
    @Test func splitsTicketAndToken() {
        let code = RemotePairingCode("  endpointabc|tok_en-1\n")
        #expect(code == RemotePairingCode("endpointabc|tok_en-1"))
        #expect(code?.ticket == "endpointabc")
        #expect(code?.token == "tok_en-1")
    }

    @Test func rejectsCodesMissingEitherHalf() {
        #expect(RemotePairingCode("") == nil)
        #expect(RemotePairingCode("ticketonly") == nil)
        #expect(RemotePairingCode("|token") == nil)
        #expect(RemotePairingCode("ticket|") == nil)
    }
}

struct RemoteScreenGeometryTests {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 500)

    @Test func widePictureInTallWindowLeavesBarsTopAndBottom() {
        let r = RemoteScreenGeometry.videoRect(remote: CGSize(width: 2000, height: 1000), in: CGRect(x: 0, y: 0, width: 1000, height: 1000))
        #expect(r == CGRect(x: 0, y: 250, width: 1000, height: 500))
    }

    @Test func mapsViewPointsToZeroToOneAcrossThePicture() {
        // 16:9 stream in a 2:1 view is pillarboxed: 888.9 wide, centred.
        let remote = CGSize(width: 1920, height: 1080)
        let mid = RemoteScreenGeometry.normalized(CGPoint(x: 500, y: 250), remote: remote, in: bounds)
        #expect(mid != nil && abs(mid!.x - 0.5) < 0.001 && abs(mid!.y - 0.5) < 0.001)
        let edge = RemoteScreenGeometry.videoRect(remote: remote, in: bounds).maxX
        let corner = RemoteScreenGeometry.normalized(CGPoint(x: edge, y: 500), remote: remote, in: bounds)
        #expect(corner != nil && abs(corner!.x - 1) < 0.001 && abs(corner!.y - 1) < 0.001)
    }

    @Test func pointsInTheBarsAreIgnoredUnlessClamped() {
        let remote = CGSize(width: 1920, height: 1080)
        #expect(RemoteScreenGeometry.normalized(CGPoint(x: 5, y: 250), remote: remote, in: bounds) == nil)
        let clamped = RemoteScreenGeometry.normalized(CGPoint(x: 5, y: 250), remote: remote, in: bounds, clamp: true)
        #expect(clamped?.x == 0)
    }

    @Test func unknownRemoteSizeFallsBackToTheWholeView() {
        #expect(RemoteScreenGeometry.videoRect(remote: .zero, in: bounds) == bounds)
    }
}

@MainActor
struct RemoteMacStoreTests {
    @Test func addingAndRemovingKeepsListAndKeychainInStep() {
        let store = RemoteMacStore()
        let before = store.macs.count
        #expect(!store.add(name: "Bad", pairingCode: "no-bar-here"))
        #expect(store.macs.count == before)

        #expect(store.add(name: " Sanctuary ", pairingCode: "ticket123|token456"))
        guard let mac = store.macs.last else { Issue.record("not saved"); return }
        #expect(mac.name == "Sanctuary")
        #expect(store.pairingCode(for: mac.id) == "ticket123|token456")

        store.remove(mac.id)
        #expect(store.macs.count == before)
        #expect(store.pairingCode(for: mac.id) == nil)
    }
}
