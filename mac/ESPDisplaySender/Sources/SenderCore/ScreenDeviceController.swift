import AppKit
import CoreVideo
import Foundation
import os
import ScreenCaptureKit
import SenderProtocol

/// What a screen device is doing, as its row and its page say it.
enum ScreenDeviceStatus: Equatable {
    case notInUse
    case starting
    case showing(String)
    case paused
    case unplugged
    case problem(String)

    var text: String {
        switch self {
        case .notInUse: return "Not in use"
        case .starting: return "Starting"
        case .showing(let host): return "Showing a region of \(host)"
        case .paused: return "Paused"
        case .unplugged:
            return "Unplugged. This screen is not connected to the Mac; it is covered "
                + "again as soon as it is plugged back in."
        case .problem(let detail): return detail
        }
    }

    /// Short form for the sidebar row.
    var shortText: String {
        switch self {
        case .unplugged: return "Unplugged"
        case .problem: return "Needs attention"
        case .showing: return "Showing"
        default: return text
        }
    }

    var needsAttention: Bool {
        switch self {
        case .unplugged, .problem: return true
        default: return false
        }
    }
}

/// Feeds a cover the pixels of a region. Behind a protocol so the controller's
/// tests run without ScreenCaptureKit.
@MainActor
protocol ScreenDeviceFeed: AnyObject {
    /// Start capturing. Returns nil once running, or why it could not start.
    /// `onFrame` is called on the main actor with the newest frame only.
    func start(
        region: RegionSpec, geometry: PanelGeometry, rotation: Int, fps: Int,
        onFrame: @escaping @MainActor (CVPixelBuffer) -> Void
    ) async -> String?
    /// Follow a region moved on the same screen without restarting. False when
    /// the running capture cannot, and the caller should restart it.
    func move(to region: RegionSpec) async -> Bool
    func stop() async
    /// Why the running capture died, once it has.
    var failure: String? { get }
}

/// The existing capture pipeline (`DisplayCapture`) in its pixel-buffer mode:
/// the region is captured at the screen's own pixel size and frame rate, fitted
/// with its aspect kept (`DisplayCapture.letterbox`), and handed over as BGRA.
@MainActor
final class LiveScreenDeviceFeed: ScreenDeviceFeed {
    private var capture: DisplayCapture?
    private var display: String?
    private let latest = LatestFrame()

    func start(
        region: RegionSpec, geometry: PanelGeometry, rotation: Int, fps: Int,
        onFrame: @escaping @MainActor (CVPixelBuffer) -> Void
    ) async -> String? {
        guard let found = await DisplayCapture.findDisplay(named: region.display) else {
            return DisplayCapture.isUnresponsive
                ? "Screen capture is not responding. It is tried again shortly."
                : "The screen \"\(region.display)\" this region is drawn on is not attached."
        }
        let latest = self.latest
        let capture = DisplayCapture(
            geometry: geometry,
            landscape: DisplayCapture.streamsLandscape(geometry: geometry, rotation: rotation),
            onPixelBuffer: { buffer, _ in latest.offer(buffer, to: onFrame) },
            onFrame: { _, _ in })
        do {
            try await capture.start(
                display: found.display, sourceRect: region.clamped(to: found.points).rect,
                fps: fps)
        } catch {
            return "Capture could not start: \(error.localizedDescription)"
        }
        self.capture = capture
        display = region.display
        return nil
    }

    func move(to region: RegionSpec) async -> Bool {
        guard let capture, region.display == display,
            let screen = DisplayCapture.screen(named: region.display)
        else { return false }
        return await capture.updateRegion(region.clamped(to: screen.frame.size).rect)
    }

    func stop() async {
        let capture = self.capture
        self.capture = nil
        await capture?.stop()
    }

    var failure: String? {
        guard let capture, capture.stopped else { return nil }
        return "Capture stopped: \(capture.stopReason ?? "no reason was given")."
    }
}

/// Hands the newest frame to the main actor, at most one hop in flight, so a
/// main thread that falls behind drops frames rather than queueing them.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CVPixelBuffer?
    private var scheduled = false

    func offer(_ buffer: CVPixelBuffer, to deliver: @escaping @MainActor (CVPixelBuffer) -> Void) {
        let schedule = lock.withLock { () -> Bool in
            pending = buffer
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
        guard schedule else { return }
        DispatchQueue.main.async { [self] in
            let next = lock.withLock { () -> CVPixelBuffer? in
                scheduled = false
                defer { pending = nil }
                return pending
            }
            guard let next else { return }
            MainActor.assumeIsolated { deliver(next) }
        }
    }
}

/// Where the screen devices are kept between launches: a file of their own
/// beside the boards' records, so nothing the boards save changes shape.
enum ScreenDeviceStore {
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("ESPDisplaySender", isDirectory: true)
            .appendingPathComponent("screen-devices.json")
    }

    static func load(from url: URL?) -> (records: [ScreenDeviceRecord], failure: String?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder.espDisplay.decode([ScreenDeviceRecord].self, from: data), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    static func save(_ records: [ScreenDeviceRecord], to url: URL) throws {
        let data = try JSONEncoder.espDisplay.encode(records)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// The Mac screens used as devices: which are listed, which are covered, what
/// each shows, and the region marquee for them.
///
/// Covers follow the screens, never the reverse: every change of the attached
/// screens re-pairs the saved devices by identity (`ScreenDeviceListing.pair`)
/// and covers exactly the screens that are theirs, so a screen unplugged loses
/// its window at once and one plugged back in gets it back.
@MainActor
final class ScreenDeviceController: ObservableObject {
    @Published private(set) var attached: [AttachedScreen] = []
    @Published private(set) var records: [ScreenDeviceRecord] = []
    @Published private(set) var statuses: [String: ScreenDeviceStatus] = [:]
    /// The device the marquee is open for.
    @Published private(set) var choosingRegionFor: String?
    /// Names of the screens covered now. No region may be drawn on one.
    private(set) var coveredDisplays: Set<String> = []

    /// Screens the boards' sources name, which are not offered as devices.
    var boardCaptureDisplays: () -> Set<String> = { [] }
    var onCoveredDisplaysChange: ((Set<String>) -> Void)?
    /// Called before the marquee opens here, so a board's marquee closes.
    var onWillChooseRegion: (() -> Void)?
    /// A save or load problem, or nil once saving works again.
    var onPersistenceProblem: ((String?) -> Void)?

    let regionSelector = RegionSelector()
    private var regionBefore: RegionSpec?

    private let readScreens: @MainActor () -> [AttachedScreen]
    private let makeCover: @MainActor (@escaping @MainActor () -> Void) -> ScreenCoverPresenting
    private let makeFeed: @MainActor () -> ScreenDeviceFeed
    private let storeURL: URL?

    private struct Output {
        let cover: ScreenCoverPresenting
        var screen: AttachedScreen
        var rotation: Int
        var feed: ScreenDeviceFeed?
        var feedRegion: RegionSpec?
        /// Renewed on every start and stop from one counter for the whole
        /// controller, so a start that finishes after it was superseded - even
        /// by a new output for the same device - throws itself away.
        var generation: Int
        /// When a capture that failed to start is tried again.
        var retryAt: Date?
    }
    private var outputs: [String: Output] = [:]
    private var lastGeneration = 0
    private func nextGeneration() -> Int {
        lastGeneration += 1
        return lastGeneration
    }
    /// A region dragged but not yet written to disk.
    private var unsaved = false
    private var work: [Task<Void, Never>] = []
    private var screenObserver: NSObjectProtocol?
    private var timer: Timer?
    static let retryInterval: TimeInterval = 10

    init(
        storeURL: URL?,
        live: Bool,
        readScreens: @escaping @MainActor () -> [AttachedScreen] = { ScreenDeviceController.liveScreens() },
        makeCover: @escaping @MainActor (@escaping @MainActor () -> Void) -> ScreenCoverPresenting = {
            displaced in
            let cover = ScreenDeviceCover()
            cover.onDisplaced = displaced
            return cover
        },
        makeFeed: @escaping @MainActor () -> ScreenDeviceFeed = { LiveScreenDeviceFeed() }
    ) {
        self.storeURL = storeURL
        self.readScreens = readScreens
        self.makeCover = makeCover
        self.makeFeed = makeFeed
        let loaded = ScreenDeviceStore.load(from: storeURL)
        records = loaded.records
        loadFailure = loaded.failure.map {
            "Saved screen devices could not be read from \(storeURL?.path ?? "disk"): \($0)"
        }
        regionSelector.onChange = { [weak self] region in self?.regionDragged(region) }
        regionSelector.onConfirm = { [weak self] in self?.finishChoosingRegion() }
        regionSelector.onCancel = { [weak self] in self?.cancelChoosingRegion() }
        regionSelector.onScale = { [weak self] scale in self?.scaleRegion(scale) }
        regionSelector.onRotate = { [weak self] in self?.rotateRegion() }
        guard live else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        reconcile()
    }

    /// Why the saved devices could not be read at launch, if they could not.
    let loadFailure: String?

    // MARK: listing

    /// The list: devices in use, then screens that could be.
    var entries: [ScreenDeviceEntry] { entries(capturingFrom: boardCaptureDisplays()) }

    /// The list, given the screens the boards capture from. The views pass
    /// them in so the list redraws when a board's source changes.
    func entries(capturingFrom: Set<String>) -> [ScreenDeviceEntry] {
        ScreenDeviceListing.entries(
            attached: attached, records: records, capturingFrom: capturingFrom)
    }

    func entry(_ key: String, capturingFrom: Set<String>? = nil) -> ScreenDeviceEntry? {
        // Devices in use are always listed; a screen that is not offered (the
        // menu-bar screen, or one something captures from) has no page.
        entries(capturingFrom: capturingFrom ?? boardCaptureDisplays()).first { $0.key == key }
    }

    func status(_ key: String) -> ScreenDeviceStatus {
        guard records.contains(where: { $0.key == key }) else { return .notInUse }
        return statuses[key] ?? .starting
    }

    func record(_ key: String) -> ScreenDeviceRecord? {
        records.first { $0.key == key }
    }

    // MARK: actions

    /// Start using a screen as a device: it is covered straight away, showing a
    /// region of the menu-bar screen in the device's shape.
    func use(_ key: String) {
        guard let offered = entry(key), !offered.inUse, let screen = offered.screen,
            !screen.hasMenuBar
        else { return }
        let host = ScreenDeviceFeedback.startingHost(
            attached: attached.filter { $0.displayID != screen.displayID },
            covered: coveredDisplays.union([screen.name]))
        let region = host.map {
            ScreenDeviceGeometry.startingRegion(on: $0, geometry: screen.geometry, rotation: 0)
        }
        records.append(ScreenDeviceRecord(screen: screen, region: region))
        save()
        reconcile()
    }

    /// Stop using a screen as a device: its window goes at once.
    func stopUsing(_ key: String) {
        if choosingRegionFor == key { finishChoosingRegion() }
        records.removeAll { $0.key == key }
        statuses[key] = nil
        save()
        reconcile()
    }

    func setPaused(_ paused: Bool, for key: String) {
        guard let index = records.firstIndex(where: { $0.key == key }),
            records[index].paused != paused
        else { return }
        records[index].paused = paused
        save()
        updateFeed(key)
    }

    /// Turn the picture clockwise. On a rectangular screen a change between an
    /// even and an odd quarter turn turns the region on its side too.
    func setRotation(_ rotation: Int, for key: String) {
        let rotation = ScreenDeviceGeometry.normalized(rotation)
        guard let index = records.firstIndex(where: { $0.key == key }),
            records[index].rotation != rotation
        else { return }
        records[index].rotation = rotation
        if let region = records[index].region, let size = hostSize(region.display) {
            records[index].region = ScreenDeviceGeometry.region(
                region, for: rotation, geometry: geometry(of: key), hostSize: size)
        }
        save()
        reconcile()
        if choosingRegionFor == key, let region = records[index].region {
            regionSelector.activeScale = region.matchingScale(geometry: geometry(of: key))
            regionSelector.apply(region)
        }
    }

    /// Take every window down, for the app quitting.
    func tearDown() {
        timer?.invalidate()
        timer = nil
        regionSelector.hide()
        for key in Array(outputs.keys) { removeOutput(key) }
        // Only what changed: a file that could not be read at launch is not
        // overwritten by quitting.
        if unsaved { save() }
    }

    // MARK: region

    var isChoosingRegion: Bool { choosingRegionFor != nil && regionSelector.isVisible }

    func chooseRegion(for key: String) {
        guard let index = records.firstIndex(where: { $0.key == key }) else { return }
        onWillChooseRegion?()
        let geometry = geometry(of: key)
        regionBefore = records[index].region
        var region = records[index].region
        if region.map({ hostSize($0.display) == nil || coveredDisplays.contains($0.display) })
            ?? true
        {
            region = ScreenDeviceFeedback.startingHost(
                attached: attached, covered: coveredDisplays
            ).map {
                ScreenDeviceGeometry.startingRegion(
                    on: $0, geometry: geometry, rotation: records[index].rotation)
            }
        }
        guard let region else {
            statuses[key] = .problem(
                "There is no screen to draw a region on: every other screen is covered.")
            return
        }
        setRegion(region, for: key)
        choosingRegionFor = key
        regionSelector.excludedDisplays = coveredDisplays
        regionSelector.allowsRotate = geometry.width == geometry.height
        regionSelector.activeScale = region.matchingScale(geometry: geometry)
        regionSelector.show(region)
    }

    func finishChoosingRegion() {
        regionSelector.hide()
        choosingRegionFor = nil
        regionBefore = nil
        if unsaved { save() }
    }

    func cancelChoosingRegion() {
        if let key = choosingRegionFor, let before = regionBefore {
            setRegion(before, for: key)
        }
        finishChoosingRegion()
    }

    private func regionDragged(_ region: RegionSpec) {
        guard let key = choosingRegionFor, !coveredDisplays.contains(region.display)
        else { return }
        setRegion(region, for: key)
        regionSelector.activeScale = region.matchingScale(geometry: geometry(of: key))
    }

    private func scaleRegion(_ scale: Int) {
        transformRegion { region, geometry, size in
            region.scaled(to: scale, geometry: geometry, in: size)
        }
    }

    private func rotateRegion() {
        transformRegion { region, _, size in region.rotated(in: size) }
    }

    private func transformRegion(_ change: (RegionSpec, PanelGeometry, CGSize) -> RegionSpec) {
        guard let key = choosingRegionFor, let region = record(key)?.region,
            let size = hostSize(region.display)
        else { return }
        let geometry = geometry(of: key)
        let updated = change(region, geometry, size)
        setRegion(updated, for: key)
        regionSelector.activeScale = updated.matchingScale(geometry: geometry)
        regionSelector.apply(updated)
    }

    func setRegion(_ region: RegionSpec, for key: String) {
        guard let index = records.firstIndex(where: { $0.key == key }) else { return }
        records[index].region = region
        unsaved = true
        updateFeed(key)
    }

    // MARK: reconciling

    /// Re-read the screens, re-pair the devices, and cover exactly theirs.
    func reconcile() {
        attached = readScreens()
        let paired = ScreenDeviceListing.pair(records, with: attached)
        learn(from: paired)
        var covering: [(record: ScreenDeviceRecord, screen: AttachedScreen)] = []
        for record in records {
            switch ScreenDeviceListing.coverDecision(for: paired[record.key]) {
            case .unplugged:
                removeOutput(record.key)
                statuses[record.key] = .unplugged
            case .menuBarScreen:
                removeOutput(record.key)
                statuses[record.key] = .problem(
                    "\(record.name) now carries the menu bar, so it is not covered. "
                        + "Move the menu bar to another screen in System Settings to "
                        + "use it as a device again.")
            case .cover(let screen):
                covering.append((record, screen))
            }
        }
        let covered = Set(covering.map(\.screen.name))
        if covered != coveredDisplays {
            coveredDisplays = covered
            regionSelector.excludedDisplays = covered
            onCoveredDisplaysChange?(covered)
        }
        for (record, screen) in covering { ensureOutput(record, on: screen) }
        let keys = Set(records.map(\.key))
        for key in outputs.keys where !keys.contains(key) { removeOutput(key) }
        statuses = statuses.filter { keys.contains($0.key) }
    }

    /// A device re-paired after its screen changed UUID or name keeps the new
    /// values, so the next pairing is exact.
    private func learn(from paired: [String: AttachedScreen]) {
        var changed = false
        for index in records.indices {
            guard let screen = paired[records[index].key] else { continue }
            if records[index].identity != screen.identity
                || records[index].name != screen.name
                || records[index].pixelWidth != screen.pixelWidth
                || records[index].pixelHeight != screen.pixelHeight
            {
                records[index].identity = screen.identity
                records[index].name = screen.name
                records[index].pixelWidth = screen.pixelWidth
                records[index].pixelHeight = screen.pixelHeight
                changed = true
            }
        }
        if changed { save() }
    }

    private func ensureOutput(_ record: ScreenDeviceRecord, on screen: AttachedScreen) {
        let key = record.key
        let existing = outputs[key]
        var output = existing ?? Output(
            cover: makeCover({ [weak self] in
                // The window was moved off its screen: start this cover afresh
                // once AppKit has finished updating the screen list, which puts
                // it back if the screen is still there and nowhere if not.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.removeOutput(key)
                        self?.reconcile()
                    }
                }
            }),
            screen: screen, rotation: record.rotation, generation: nextGeneration())
        let reshaped = existing == nil || existing?.rotation != record.rotation
            || existing?.screen.pixelWidth != screen.pixelWidth
            || existing?.screen.pixelHeight != screen.pixelHeight
        if existing == nil || existing?.screen != screen || reshaped {
            output.cover.cover(screen, rotation: record.rotation)
        }
        output.screen = screen
        output.rotation = record.rotation
        outputs[key] = output
        // A new frame size needs a new capture; the cover keeps its last frame
        // until the new one arrives.
        if reshaped, existing != nil { stopFeed(key) }
        updateFeed(key)
    }

    private func removeOutput(_ key: String) {
        guard let output = outputs.removeValue(forKey: key) else { return }
        output.cover.remove()
        if let feed = output.feed { track(Task { await feed.stop() }) }
    }

    private func stopFeed(_ key: String) {
        guard var output = outputs[key] else { return }
        output.generation = nextGeneration()
        let feed = output.feed
        output.feed = nil
        output.feedRegion = nil
        outputs[key] = output
        if let feed { track(Task { await feed.stop() }) }
    }

    /// Bring the capture in line with the record: stopped while paused or with
    /// nothing to show, moved for a region dragged on the same screen, and
    /// restarted for anything else.
    private func updateFeed(_ key: String) {
        guard let output = outputs[key], let record = record(key) else { return }
        if record.paused {
            stopFeed(key)
            statuses[key] = .paused
            return
        }
        guard let region = record.region else {
            stopFeed(key)
            output.cover.clear()
            statuses[key] = .problem("Choose a region for this device to show.")
            return
        }
        guard !coveredDisplays.contains(region.display) else {
            stopFeed(key)
            output.cover.clear()
            statuses[key] = .problem(
                "This region is drawn on \(region.display), which is itself used as a "
                    + "device. Adjust the region onto another screen.")
            return
        }
        guard hostSize(region.display) != nil else {
            stopFeed(key)
            output.cover.clear()
            statuses[key] = .problem(
                "The screen \"\(region.display)\" this region is drawn on is not attached.")
            return
        }
        if let feed = output.feed, feed.failure == nil, let running = output.feedRegion {
            guard running != region else { return }
            if running.display == region.display {
                outputs[key]?.feedRegion = region
                let generation = output.generation
                track(Task { [weak self] in
                    guard await !feed.move(to: region),
                        let self, self.outputs[key]?.generation == generation
                    else { return }
                    self.restartFeed(key)
                })
                return
            }
        }
        restartFeed(key)
    }

    private func restartFeed(_ key: String) {
        stopFeed(key)
        guard var output = outputs[key], let record = record(key), let region = record.region
        else { return }
        let feed = makeFeed()
        output.feed = feed
        output.feedRegion = region
        output.retryAt = nil
        let generation = output.generation
        outputs[key] = output
        statuses[key] = .starting
        let screen = output.screen
        track(Task { [weak self] in
            let failure = await feed.start(
                region: region, geometry: screen.geometry, rotation: record.rotation,
                fps: max(1, screen.maximumFPS),
                onFrame: { [weak self] frame in
                    guard let output = self?.outputs[key], output.generation == generation
                    else { return }
                    output.cover.present(frame)
                })
            guard let self, self.outputs[key]?.generation == generation else {
                await feed.stop()
                return
            }
            if let failure {
                self.outputs[key]?.feed = nil
                self.outputs[key]?.feedRegion = nil
                self.outputs[key]?.retryAt = Date().addingTimeInterval(Self.retryInterval)
                self.outputs[key]?.cover.clear()
                self.statuses[key] = .problem(failure)
            } else {
                self.statuses[key] = .showing(region.display)
            }
        })
    }

    /// Every two seconds: put a cover back on top if something ordered it out,
    /// and restart a capture that died or retry one that would not start.
    func tick() {
        for (key, output) in outputs {
            output.cover.reassert()
            guard let record = record(key), !record.paused else { continue }
            if let feed = output.feed, let failure = feed.failure {
                // The reason stays up until a restart succeeds, which waits
                // `retryInterval` so a stream that keeps dying is not rebuilt
                // every two seconds.
                stopFeed(key)
                outputs[key]?.retryAt = Date().addingTimeInterval(Self.retryInterval)
                output.cover.clear()
                statuses[key] = .problem(failure)
            } else if output.feed == nil, let retryAt = output.retryAt, retryAt <= Date() {
                updateFeed(key)
            }
        }
    }

    // MARK: helpers

    private func geometry(of key: String) -> PanelGeometry {
        let record = record(key)
        let screen = outputs[key]?.screen
        return screen?.geometry ?? record?.geometry ?? .panel172x320
    }

    private func hostSize(_ display: String) -> CGSize? {
        attached.first { $0.name == display }?.frame.size
    }

    private func track(_ task: Task<Void, Never>) {
        work.removeAll { $0.isCancelled }
        work.append(task)
    }

    /// Wait for every start, move and stop in flight. For tests.
    func settle() async {
        while !work.isEmpty {
            let pending = work
            work = []
            for task in pending { await task.value }
        }
    }

    private func save() {
        guard let storeURL else { return }
        do {
            try ScreenDeviceStore.save(records, to: storeURL)
            unsaved = false
            onPersistenceProblem?(nil)
        } catch {
            onPersistenceProblem?(
                "Screen devices could not be saved to \(storeURL.path): "
                    + error.localizedDescription)
        }
    }

    /// The Mac's screens as AppKit reports them.
    static func liveScreens() -> [AttachedScreen] {
        let main = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID
            else { return nil }
            let scale = screen.backingScaleFactor
            return AttachedScreen(
                displayID: id,
                identity: ScreenIdentity(
                    vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                    serial: CGDisplaySerialNumber(id), uuid: DisplayCapture.uuid(for: id)),
                name: screen.localizedName,
                pixelWidth: Int((screen.frame.width * scale).rounded()),
                pixelHeight: Int((screen.frame.height * scale).rounded()),
                frame: screen.frame,
                maximumFPS: max(1, screen.maximumFramesPerSecond),
                hasMenuBar: id == main)
        }
    }
}
