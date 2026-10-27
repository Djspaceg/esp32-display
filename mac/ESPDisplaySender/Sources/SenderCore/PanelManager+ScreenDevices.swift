import Foundation
import SenderProtocol

/// Mac screens used as devices, as the boards' side sees them: which screens
/// they may not be offered, one marquee at a time, and their saving problems
/// in the same banner as everyone else's.
extension PanelManager {
    static let screenDevicesIssueSource = "screen devices"
    static let screenDevicesReadIssueSource = "screen devices (read)"

    func wireScreenDevices() {
        screenDevices.boardCaptureDisplays = { [weak self] in
            self?.boardCaptureDisplayNames() ?? []
        }
        screenDevices.onCoveredDisplaysChange = { [weak self] names in
            self?.applyCoveredDisplays(names)
        }
        screenDevices.onWillChooseRegion = { [weak self] in
            guard let self, self.regionSelector.isVisible else { return }
            self.finishChoosingRegion()
        }
        screenDevices.onPersistenceProblem = { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.report(.persistence, source: Self.screenDevicesIssueSource, detail: problem)
            } else {
                self.resolve(.persistence, source: Self.screenDevicesIssueSource)
            }
        }
        if let failure = screenDevices.loadFailure {
            report(.persistence, source: Self.screenDevicesReadIssueSource, detail: failure)
        }
        applyCoveredDisplays(screenDevices.coveredDisplays)
    }

    /// The screens the boards capture from, by name, which are not offered as
    /// devices: covering one would leave its board showing the cover.
    func boardCaptureDisplayNames() -> Set<String> {
        Set(panels.compactMap { panel -> String? in
            switch panel.source {
            case .region(let region): return region.display
            case .display(let name): return name
            case .automatic, .window: return nil
            }
        })
    }

    /// A screen used as a device shows this app's own picture, so a board is
    /// not pointed at it; says so and returns true when `name` is one.
    func refusesCoveredScreen(_ name: String) -> Bool {
        guard coveredDisplayNames.contains(name) else { return false }
        operationOutcome = .failure(
            "Screen in use as a device",
            "\(name) is used as a device, so a board cannot show it. Stop using it "
                + "as a device first, or choose another screen.")
        return true
    }

    func applyCoveredDisplays(_ names: Set<String>) {
        coveredDisplayNames = names
        regionSelector.excludedDisplays = names
        refreshDisplays()
    }
}
