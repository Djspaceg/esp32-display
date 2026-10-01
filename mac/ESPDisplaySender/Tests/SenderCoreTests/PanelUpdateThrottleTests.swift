import Combine
import XCTest

@testable import SenderCore
@testable import SenderProtocol

/// While audio streams, the panel's audio snapshot changes four or more times a
/// second (panel status every 250 ms, plus one per playback-queue drop) and the
/// heartbeat once a second. Each write to `panels` re-renders the whole window,
/// so the views must see at most one telemetry update per 500 ms per panel, with
/// state changes (Streaming to Recovering) still shown at once.
@MainActor
final class PanelUpdateThrottleTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_000)
    private var scheduled: [(at: Date, work: @MainActor () -> Void)] = []
    private var publishes = 0
    private var cancellable: AnyCancellable?

    private func makeManager() -> PanelManager {
        let manager = PanelManager(
            previewPanels: [PanelSnapshot(serviceName: "desk", displayName: "desk")],
            savedNetworkNames: [], usbSerialPorts: [])
        manager.telemetryNow = { [unowned self] in self.now }
        manager.scheduleTelemetryFlush = { [unowned self] delay, work in
            self.scheduled.append((self.now.addingTimeInterval(delay), work))
        }
        cancellable = manager.$panels.dropFirst().sink { [unowned self] _ in
            self.publishes += 1
        }
        return manager
    }

    /// Advance the fake clock, running any flush that has come due.
    private func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        let due = scheduled.filter { $0.at <= now }
        scheduled.removeAll { $0.at <= now }
        for item in due { item.work() }
    }

    private func snapshot(
        _ state: PanelAudioState, drops: UInt64
    ) -> PanelAudioSnapshot {
        PanelAudioSnapshot(
            state: state,
            message: "m",
            sourceName: "in",
            uplinkDestination: "out",
            descriptor: AudioStreamDescriptor(
                port: 5569, version: 1, sampleRateHz: 16_000,
                playbackChannels: 2, captureChannels: 2),
            tuning: AudioRuntimeTuning(),
            panelStatus: nil,
            downlinkQueueDrops: drops,
            captureCallbackDrops: 0,
            uplinkLostFrames: 0,
            uplinkLatePackets: 0,
            downlinkCorrectionPPM: 0)
    }

    func testAudioCounterBurstIsCoalescedToTwoUpdatesASecond() {
        let manager = makeManager()
        manager.updateAudio(snapshot(.streaming, drops: 0), for: "desk")
        let afterFirst = publishes
        XCTAssertEqual(afterFirst, 1, "the first snapshot is shown at once")
        // 100 counter-only snapshots over one second.
        for drops in 1...100 {
            advance(0.01)
            manager.updateAudio(snapshot(.streaming, drops: UInt64(drops)), for: "desk")
        }
        advance(0.5)
        XCTAssertLessThanOrEqual(
            publishes - afterFirst, 3,
            "one second of counters may reach the views at most every 500 ms")
        XCTAssertEqual(
            manager.panels.first?.audioStatus?.downlinkQueueDrops, 100,
            "the trailing flush still shows the latest counters")
    }

    func testAudioStateChangeIsShownImmediately() {
        let manager = makeManager()
        manager.updateAudio(snapshot(.streaming, drops: 0), for: "desk")
        advance(0.01)
        manager.updateAudio(snapshot(.recovering, drops: 0), for: "desk")
        XCTAssertEqual(manager.panels.first?.audioStatus?.state, .recovering)
        advance(0.01)
        manager.updateAudio(snapshot(.streaming, drops: 0), for: "desk")
        XCTAssertEqual(manager.panels.first?.audioStatus?.state, .streaming)
    }

    /// An urgent write cancels the flush scheduled before it, so the old
    /// closure cannot add a second write inside the next 500 ms.
    func testUrgentWriteCancelsTheEarlierScheduledFlush() {
        let manager = makeManager()
        manager.updateAudio(snapshot(.streaming, drops: 0), for: "desk")   // t=0 write
        advance(0.1)
        manager.updateAudio(snapshot(.streaming, drops: 1), for: "desk")   // schedules 0.5
        advance(0.1)
        manager.updateAudio(snapshot(.recovering, drops: 1), for: "desk")  // t=0.2 urgent
        let afterUrgent = publishes
        advance(0.1)
        manager.updateAudio(snapshot(.recovering, drops: 2), for: "desk")  // t=0.3
        advance(0.25)                                                       // t=0.55
        XCTAssertEqual(
            publishes, afterUrgent,
            "nothing reaches the views within 500 ms of the urgent write")
        advance(0.2)                                                        // t=0.75
        XCTAssertEqual(publishes, afterUrgent + 1)
        XCTAssertEqual(manager.panels.first?.audioStatus?.downlinkQueueDrops, 2)
    }

    /// Clearing audio drops held audio but not a held heartbeat.
    func testClearAudioDropsHeldAudioOnly() {
        let manager = makeManager()
        manager.updateAudio(snapshot(.streaming, drops: 0), for: "desk")
        manager.update(.heartbeat(FrameSender.DeviceStats(shown: 1)), for: "desk")
        advance(0.1)
        manager.updateAudio(snapshot(.streaming, drops: 5), for: "desk")
        manager.update(.heartbeat(FrameSender.DeviceStats(shown: 9)), for: "desk")
        manager.clearAudio(for: "desk")
        advance(0.5)
        XCTAssertNil(manager.panels.first?.audioStatus)
        XCTAssertEqual(manager.panels.first?.framesShown, 9)
    }

    func testHeartbeatsShareTheSameBudget() {
        let manager = makeManager()
        manager.update(
            .heartbeat(FrameSender.DeviceStats(shown: 1)),
            for: "desk")
        let afterFirst = publishes
        for tick in 1...20 {
            advance(0.05)
            manager.updateAudio(snapshot(.streaming, drops: UInt64(tick)), for: "desk")
            if tick % 4 == 0 {
                manager.update(
                    .heartbeat(FrameSender.DeviceStats(shown: UInt32(tick))),
                    for: "desk")
            }
        }
        advance(0.5)
        XCTAssertLessThanOrEqual(
            publishes - afterFirst, 4,
            "audio and heartbeat telemetry together stay within one update per 500 ms")
        XCTAssertEqual(manager.panels.first?.framesShown, 20)
    }
}
