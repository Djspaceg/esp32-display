import Foundation
import IOKit
import SenderProtocol

/// The one esptool of a repair run, started ahead of the plug-in and waiting on
/// a link. A protocol so the loop can be driven by a fake in tests.
protocol RescueWorker: AnyObject {
    /// esptool has printed `UsbRescue.readyMarker` and is waiting.
    var isReady: Bool { get }
    /// esptool has printed `UsbRescue.connectedMarker` since the last link.
    var isConnected: Bool { get }
    /// Read what esptool printed; its exit code once it has exited.
    func poll() -> Int32?
    /// Output printed since the last call, only while linked.
    func takeOutput() -> String
    func link(to port: String) throws
    func unlink()
    func lastError() -> String
    /// Stop the whole esptool process tree and remove the link.
    func kill()
}

/// The I/O half of repairing a board that drops off USB right after boot:
/// esptool processes, a symlink, the /dev listing and the IORegistry. Every
/// decision is `UsbRescue`'s; the loop is `run_rescue` in tools/espdisp.py.
///
/// NO PORT IS EVER OPENED BY THIS CODE while it waits. Ports are listed from
/// /dev by name and devices are read from the IORegistry. The only thing that
/// opens the board is esptool, through its link, and only after exactly one
/// port has appeared that was not there when the user was told to plug in.
enum UsbRescuer {

    /// Everything the loop touches outside itself, so a test can drive it with
    /// a virtual clock, a fake /dev and fake esptools.
    struct IO {
        var ports: () -> [String]
        var identify: () -> [UsbRescue.USBIdentity]
        /// The device that publishes a port, from the IORegistry; nil when it
        /// cannot be found there, and the name is parsed instead.
        var identifyPort: (String) -> UsbRescue.USBIdentity? = { _ in nil }
        var spawn: () throws -> RescueWorker
        var now: () -> Double
        var sleep: (Double) async -> Void
        var isCancelled: () -> Bool
    }

    // MARK: - the loop

    /// Wait for one new USB port and let the waiting esptool rescue it.
    ///
    /// Returns the port once esptool has written the image. A port attached
    /// before "Plug the board in now" is never touched, even when it drops off
    /// and comes back, and neither is a new port whose USB device (by location
    /// or serial) was attached then. Runs until then, a failure, or cancel;
    /// whatever esptool is running is killed on every way out.
    static func run(
        family: UsbRescue.Family,
        regions: [UsbRescue.Region],
        io: IO,
        onProgress: (UsbFlashEvent) -> Void
    ) async throws -> String {
        func say(_ text: String) { onProgress(.log(.app, text)) }
        var lastStep: UsbRescueStep?
        func report(_ step: UsbRescueStep) {
            guard step != lastStep else { return }
            lastStep = step
            onProgress(.phase(.rescue(step)))
        }

        var baseline = Set(io.ports())
        var knownDevices = Set(io.identify())
        report(.startingEsptool)
        // Everything attached now is left alone for the whole run, however it
        // is replugged: the same socket gives the same name, and another
        // socket the same USB device. So the board must be unplugged BEFORE
        // Start, and the words say so rather than "unplug it now".
        say("Starting esptool; this takes a few seconds. Keep the board to repair "
            + "unplugged until this says \"Plug the board in now\".")
        if !baseline.isEmpty {
            say("Attached now, so left alone for this whole repair: "
                + baseline.sorted().joined(separator: ", ") + ". If one of them is "
                + "the board to repair, stop, unplug it, and start again.")
        }
        var worker = try io.spawn()
        defer { worker.kill() }

        var started = false      // "plug in now" has been said once
        var announced = false    // ...and holds for the current esptool
        var missed = false       // the last attempt ended in a miss
        var linked: (port: String, since: Double, connectedAt: Double?)?
        var refused = Set<String>()
        /// Failed writes in a row per port, while it stays attached.
        var failures: [String: Int] = [:]
        var gone = Set<String>()
        var toldIgnored = Set<String>()
        var toldCrowd = false
        var toldWait: String?
        var echo = Echo(regions: regions)

        func relaunch() throws {
            worker.kill()
            worker = try io.spawn()
            announced = false
        }

        while true {
            if io.isCancelled() {
                throw WifiConfigUI.ConfigFailure(
                    title: "Stopped", message: "The repair was stopped. Nothing more was written.")
            }
            let now = io.now()
            let present = Set(io.ports())
            if !started {
                let early = present.subtracting(baseline)
                if !early.isEmpty {
                    knownDevices.formUnion(io.identify())
                    say("Ignoring " + early.sorted().joined(separator: ", ")
                        + ": it appeared before esptool was ready, so it is left alone "
                        + "for this repair. If that is the board, stop, unplug it, "
                        + "and start again.")
                }
                baseline.formUnion(present)
            }
            let code = worker.poll()
            if linked != nil {
                echo.feed(worker.takeOutput(), onProgress)
            }
            if let code {
                guard let port = linked?.port else {
                    let reason = worker.lastError()
                    throw WifiConfigUI.ConfigFailure(
                        title: "esptool stopped while waiting for the board",
                        message: reason.isEmpty ? "It exited with status \(code)." : reason)
                }
                echo.finish(onProgress)
                linked = nil
                if code == 0 {
                    report(.rescued(port: port))
                    return port
                }
                let reason = worker.lastError()
                if !reason.isEmpty { say("esptool: \(reason)") }
                if present.contains(port) {
                    // A board of another family fails at once and every time;
                    // relaunching would reset it every few seconds for good.
                    failures[port, default: 0] += 1
                    let wrongChip = UsbRescue.isWrongChip(reason)
                    if wrongChip || failures[port, default: 0] >= UsbRescue.failuresBeforeRefusal {
                        refused.insert(port)
                        say("esptool could not write \(port) ("
                            + (wrongChip ? "it is another chip"
                                : "\(failures[port, default: 0]) failed attempts")
                            + "); is it an \(family.displayName) board? Unplug it.")
                        report(.couldNotConnect(port: port, family: family.key))
                    } else {
                        say("esptool could not finish on \(port); trying again.")
                    }
                } else {
                    say("Missed it. Unplug the board, then plug it in again.")
                    missed = true
                    report(.missed(esptoolReady: false))
                }
                try relaunch()
                continue
            }
            if worker.isReady, !announced {
                say(started ? "esptool is waiting again." : "Plug the board in now.")
                started = true
                announced = true
                if refused.isEmpty {
                    report(missed ? .missed(esptoolReady: true) : .plugIn)
                }
            }
            if linked != nil, worker.isConnected, linked?.connectedAt == nil {
                linked?.connectedAt = now
            }
            if let current = linked {
                if let connectedAt = current.connectedAt,
                   now - connectedAt > UsbRescue.writeTimeout {
                    // Connected but never finished: killed, and counted like a
                    // failed write, so a board that always hangs is let go.
                    try relaunch()
                    linked = nil
                    echo.finish(onProgress)
                    failures[current.port, default: 0] += 1
                    if failures[current.port, default: 0] >= UsbRescue.failuresBeforeRefusal {
                        refused.insert(current.port)
                        say("esptool stopped writing to \(current.port) \(failures[current.port, default: 0]) "
                            + "times; is it an \(family.displayName) board? Unplug it.")
                        report(.couldNotConnect(port: current.port, family: family.key))
                    } else {
                        say("esptool stopped writing to \(current.port) for "
                            + "\(Int(UsbRescue.writeTimeout)) s; trying again.")
                    }
                } else if !present.contains(current.port), !worker.isConnected {
                    worker.unlink()
                    linked = nil
                    missed = true
                    say("Missed it. Unplug the board, then plug it in again.")
                    report(.missed(esptoolReady: true))
                } else if present.contains(current.port), !worker.isConnected,
                          now - current.since > UsbRescue.connectTimeout {
                    // Killed, not just unlinked: an esptool part-way through a
                    // connect pass still holds the port open and could go on to
                    // write a board it was just told to give up.
                    try relaunch()
                    linked = nil
                    refused.insert(current.port)
                    say("esptool could not connect to \(current.port) in "
                        + "\(Int(UsbRescue.connectTimeout)) s; is it an "
                        + "\(family.displayName) board? Unplug it.")
                    report(.couldNotConnect(port: current.port, family: family.key))
                }
            } else if started {
                let hadRefused = !refused.isEmpty
                refused.formIntersection(present)
                failures = failures.filter { present.contains($0.key) }
                if hadRefused, refused.isEmpty, worker.isReady {
                    report(missed ? .missed(esptoolReady: true) : .plugIn)
                }
                for port in baseline.sorted() {
                    if !present.contains(port) {
                        gone.insert(port)
                    } else if gone.contains(port), !toldIgnored.contains(port) {
                        toldIgnored.insert(port)
                        say("Ignoring \(port): it was attached before the repair started. "
                            + "If that is the board to repair, stop, unplug it, and "
                            + "start again.")
                    }
                }
                var fresh = UsbRescue.newPorts(baseline: baseline, present: present)
                    .filter { !refused.contains($0) }
                if fresh.count == 1,
                   UsbRescue.isKnown(
                       io.identifyPort(fresh[0])
                           ?? UsbRescue.identity(forPort: fresh[0], devices: io.identify()),
                       in: knownDevices) {
                    baseline.insert(fresh[0])
                    say("Ignoring \(fresh[0]): it is the same USB device as one "
                        + "attached before the repair started.")
                    fresh = []
                }
                if fresh.count > 1 {
                    if !toldCrowd {
                        say("\(fresh.count) new ports appeared (\(fresh.joined(separator: ", "))); "
                            + "touching none of them. Leave only the board to repair "
                            + "plugged in.")
                        toldCrowd = true
                        report(.tooManyPorts(fresh))
                    }
                } else if let port = fresh.first {
                    toldCrowd = false
                    if !worker.isReady {
                        if toldWait != port {
                            say("Board seen on \(port), but esptool is still starting; "
                                + "keep it plugged in.")
                            toldWait = port
                            report(.seenWhileStarting(port: port))
                        }
                    } else {
                        try worker.link(to: port)
                        linked = (port, now, nil)
                        toldWait = nil
                        missed = false
                        echo = Echo(regions: regions)
                        say("Board seen on \(port); resetting it into download mode.")
                        report(.caught(port: port))
                    }
                } else {
                    if toldCrowd, worker.isReady, refused.isEmpty {
                        report(missed ? .missed(esptoolReady: true) : .plugIn)
                    }
                    toldCrowd = false
                    toldWait = nil
                }
            }
            await io.sleep(UsbRescue.pollSeconds)
        }
    }

    /// esptool's output after the link, as transcript lines and flash phases.
    private struct Echo {
        var tracker: EsptoolFlashTracker
        var pending = ""

        init(regions: [UsbRescue.Region]) {
            tracker = EsptoolFlashTracker(parts: regions.map {
                .init(role: $0.role, address: $0.address, size: $0.bytes)
            })
        }

        mutating func feed(_ text: String, _ onProgress: (UsbFlashEvent) -> Void) {
            guard !text.isEmpty else { return }
            let split = EsptoolOutput.splitLines(pending + UsbRescue.strippingTerminalCodes(text))
            pending = split.remainder
            split.lines.forEach { emit($0, onProgress) }
        }

        mutating func finish(_ onProgress: (UsbFlashEvent) -> Void) {
            emit(pending, onProgress)
            pending = ""
        }

        private mutating func emit(_ line: String, _ onProgress: (UsbFlashEvent) -> Void) {
            guard EsptoolOutput.isStatusWorthy(line) else { return }
            onProgress(.log(.esptool, line))
            if let phase = tracker.consume(line) { onProgress(.phase(phase)) }
        }
    }

    // MARK: - the real esptool

    /// One waiting esptool on its own link.
    final class EsptoolWorker: RescueWorker {
        let link: String
        private let process: EsptoolRunner.WaitingProcess
        private(set) var isReady = false
        private(set) var isConnected = false
        private var linkedPort: String?
        private var tail = ""
        private var sinceLink = ""
        private var echo = ""

        init(process: EsptoolRunner.WaitingProcess, link: String) {
            self.process = process
            self.link = link
        }

        private var linkFile: String { UsbRescue.linkFile(for: link) }

        private func read() {
            let text = process.read()
            guard !text.isEmpty else { return }
            tail = String((tail + text).suffix(4096))
            if !isReady {
                isReady = tail.contains(UsbRescue.readyMarker)
            } else if linkedPort != nil {
                sinceLink = String((sinceLink + text).suffix(4096))
                isConnected = isConnected || sinceLink.contains(UsbRescue.connectedMarker)
                echo += text
            }
        }

        func poll() -> Int32? {
            read()
            let code = process.poll()
            if code != nil { read() }
            return code
        }

        func takeOutput() -> String {
            defer { echo = "" }
            return echo
        }

        func link(to port: String) throws {
            unlink()
            try FileManager.default.createSymbolicLink(
                atPath: linkFile, withDestinationPath: port)
            linkedPort = port
            sinceLink = ""
        }

        func unlink() {
            try? FileManager.default.removeItem(atPath: linkFile)
            linkedPort = nil
        }

        func lastError() -> String { UsbRescue.lastError(in: tail) }

        func kill() {
            unlink()
            process.kill()
        }
    }

    /// A function starting one waiting esptool per call, each on its own link,
    /// all under `work`, which the caller creates and removes.
    static func spawner(
        family: UsbRescue.Family,
        regions: [UsbRescue.Region],
        work: URL,
        tool: EsptoolCommand.Tool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launch: @escaping (EsptoolCommand, [String: String], String) throws -> RescueWorker
            = { command, environment, link in
                EsptoolWorker(
                    process: try EsptoolRunner.WaitingProcess(
                        command, environment: environment,
                        directory: (UsbRescue.linkFile(for: link) as NSString)
                            .deletingLastPathComponent),
                    link: link)
            }
    ) throws -> () throws -> RescueWorker {
        let config = work.appendingPathComponent("esptool.cfg")
        try UsbRescue.esptoolConfig.write(to: config, atomically: true, encoding: .utf8)
        // The environment spelling of open_port_attempts outranks the file, so
        // it is pinned too; ESPTOOL_CFGFILE keeps a user's own config out of it.
        var environment = environment
        environment["ESPTOOL_CFGFILE"] = config.path
        environment["ESPTOOL_OPEN_PORT_ATTEMPTS"] = "0"
        let writes = regions.map {
            EsptoolCommand.StagedWrite(role: $0.role, address: $0.address, path: $0.path)
        }
        var count = 0
        return { [environment] in
            let link = UsbRescue.linkPath(directory: work.path, index: count)
            count += 1
            let command = try EsptoolCommand.rescueWriteFlash(
                tool: tool, chip: family.chip, port: link, baud: family.baud, writes: writes)
            return try launch(command, environment, link)
        }
    }

    /// The USB device that publishes a serial port, found by walking up the
    /// IORegistry from the port's IOSerialBSDClient: no name parsing and no
    /// port opened. nil when the port is not (or no longer) registered.
    static func usbDevice(forPort port: String) -> UsbRescue.USBIdentity? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOSerialBSDClient"), &iterator)
            == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(
                entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard property(service, "IOCalloutDevice") as? String == port else { continue }
            var entry = service
            IOObjectRetain(entry)
            while true {
                if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                    defer { IOObjectRelease(entry) }
                    guard let location = (property(entry, "locationID") as? NSNumber)?.intValue
                    else { return nil }
                    return UsbRescue.USBIdentity(
                        location: location,
                        serial: property(entry, "USB Serial Number") as? String ?? "")
                }
                var parent: io_registry_entry_t = 0
                let result = IORegistryEntryGetParentEntry(entry, "IOService", &parent)
                IOObjectRelease(entry)
                guard result == KERN_SUCCESS else { return nil }
                entry = parent
            }
        }
        return nil
    }

    /// The attached USB devices, read from the IORegistry without opening any.
    static func usbDevices() -> [UsbRescue.USBIdentity] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [UsbRescue.USBIdentity] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(
                    service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let location = (property("locationID") as? NSNumber)?.intValue else { continue }
            devices.append(UsbRescue.USBIdentity(
                location: location, serial: property("USB Serial Number") as? String ?? ""))
        }
        return devices
    }

    // MARK: - after the write

    /// What the rescue image said about the board it is running on.
    struct RescuedBoard: Equatable, Sendable {
        var port: String
        /// The family the user chose, which the image written was built for.
        var family: UsbRescue.Family
        var identity: WifiConfigUI.USBIdentity
        /// The profile a stored CFGBOARD override forces, if any.
        var storedOverride: String?
        /// The carrier the user named before the rescue image was written, for
        /// a family that needs one (P4); nil otherwise.
        var carrier: String? = nil
    }

    /// Ask the freshly rescued board, on that port only, what it is.
    ///
    /// The rescue image reboots after the write and its USB port comes back
    /// within a second or two, so a missing reply is retried a few times.
    static func readRescuedBoard(
        port: String,
        family: UsbRescue.Family,
        attempts: Int = 8,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        send: (String, String, WifiConfigUI.SerialLog?) -> WifiConfigUI.CommandResult = {
            WifiConfigUI.sendCommand($0, port: $1, timeout: 2, log: $2)
        },
        sleep: (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        onProgress: @escaping @Sendable (UsbFlashEvent) -> Void
    ) async -> RescuedBoard? {
        onProgress(.phase(.rescue(.readingBoard(port: port))))
        let log: WifiConfigUI.SerialLog = { source, text in onProgress(.log(source, text)) }
        for _ in 0..<attempts {
            if Task.isCancelled { return nil }
            if exists(port), case .success(let reply) = send("CFGSHOW", port, log),
               reply.hasPrefix("CFGINFO") {
                return RescuedBoard(
                    port: port, family: family,
                    identity: WifiConfigUI.usbIdentity(from: reply),
                    storedOverride: UsbRescue.storedOverride(inReply: reply))
            }
            await sleep(1)
        }
        return nil
    }
}
