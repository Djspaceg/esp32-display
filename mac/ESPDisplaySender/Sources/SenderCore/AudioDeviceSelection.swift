import Foundation

enum AudioDeviceDirection: Sendable {
    case input
    case output
}

struct AudioDevicePreferences: Codable, Equatable, Sendable {
    var inputUID: String?
    var outputUID: String?

    init(inputUID: String? = nil, outputUID: String? = nil) {
        self.inputUID = inputUID
        self.outputUID = outputUID
    }
}

/// Stable CoreAudio identity shown by the settings dropdowns.
struct AudioDeviceOption: Identifiable, Equatable, Sendable {
    var id: String { uid }

    let uid: String
    let name: String
    let supportsInput: Bool
    let supportsOutput: Bool

    func supports(_ direction: AudioDeviceDirection) -> Bool {
        switch direction {
        case .input: return supportsInput
        case .output: return supportsOutput
        }
    }
}

struct AudioDeviceResolution: Equatable, Sendable {
    let uid: String?
    let name: String
    let missingPreferredUID: String?

    var usedFallback: Bool { missingPreferredUID != nil }
}

/// Pure preference resolution. CoreAudio enumeration is deliberately outside
/// this type so vanished-device behavior is unit-testable without hardware.
enum AudioDeviceResolver {
    static let systemDefaultName = "System Default"

    static func resolve(
        preferredUID: String?,
        direction: AudioDeviceDirection,
        devices: [AudioDeviceOption]
    ) -> AudioDeviceResolution {
        guard let preferredUID, !preferredUID.isEmpty else {
            return AudioDeviceResolution(
                uid: nil, name: systemDefaultName, missingPreferredUID: nil)
        }
        if let device = devices.first(where: {
            $0.uid == preferredUID && $0.supports(direction)
        }) {
            return AudioDeviceResolution(
                uid: device.uid, name: device.name, missingPreferredUID: nil)
        }
        return AudioDeviceResolution(
            uid: nil,
            name: systemDefaultName,
            missingPreferredUID: preferredUID)
    }
}
