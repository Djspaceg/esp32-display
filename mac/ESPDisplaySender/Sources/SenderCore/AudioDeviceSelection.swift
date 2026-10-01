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
