import AppKit
import Foundation
import SenderProtocol

/// A key combination recorded for a custom key-press assignment.
///
/// The label is taken when the keys are recorded, from what the keyboard
/// layout said the key was, because a key code alone cannot be named again
/// without the layout that was active then.
struct KeyCombo: Hashable, Sendable {
    let keyCode: UInt16
    /// `NSEvent.ModifierFlags` raw value, limited to command, option, control
    /// and shift.
    let modifiers: UInt
    let label: String

    static let recordedModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.recordedModifiers)
    }

    /// The combination a key-down event records, or nil for an event with no
    /// key (a modifier on its own).
    static func recorded(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> KeyCombo? {
        guard let name = keyName(
            keyCode: keyCode, characters: charactersIgnoringModifiers)
        else { return nil }
        let flags = modifiers.intersection(recordedModifiers)
        var symbols = ""
        if flags.contains(.control) { symbols += "\u{2303}" }
        if flags.contains(.option) { symbols += "\u{2325}" }
        if flags.contains(.shift) { symbols += "\u{21E7}" }
        if flags.contains(.command) { symbols += "\u{2318}" }
        return KeyCombo(keyCode: keyCode, modifiers: flags.rawValue,
                        label: symbols + name)
    }

    /// Keys whose character is invisible or misleading, by virtual key code
    /// (Carbon's kVK_* values, which are layout-independent).
    private static let namedKeys: [UInt16: String] = [
        36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape",
        76: "Enter", 117: "Forward Delete", 115: "Home", 119: "End",
        116: "Page Up", 121: "Page Down", 123: "\u{2190}", 124: "\u{2192}",
        125: "\u{2193}", 126: "\u{2191}",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
        80: "F19", 90: "F20",
    ]

    /// Modifier keys themselves (shift, control, option, command, caps lock,
    /// fn), which name no key to press.
    private static let modifierKeyCodes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    private static func keyName(keyCode: UInt16, characters: String?) -> String? {
        if modifierKeyCodes.contains(keyCode) { return nil }
        if let named = namedKeys[keyCode] { return named }
        guard let characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 0x21 })
        else { return "Key \(keyCode)" }
        return characters.uppercased()
    }
}

/// What a board can run on itself, without this Mac.
enum BoardFunction: CaseIterable, Hashable, Sendable {
    case statusScreen
    case wifiSelector
    case bootMenu
    case rotate180
    case displayPower

    var code: DeviceProtocol.BoardFunctionCode {
        switch self {
        case .statusScreen: return .statusScreen
        case .wifiSelector: return .wifiSelector
        case .bootMenu: return .bootMenu
        case .rotate180: return .rotate180
        case .displayPower: return .displayPower
        }
    }

    init?(code: DeviceProtocol.BoardFunctionCode) {
        guard let function = (Self.allCases.first { $0.code == code }) else { return nil }
        self = function
    }

    var summary: String {
        switch self {
        case .statusScreen: return "Show or hide the WiFi status screen"
        case .wifiSelector: return "Open the WiFi selector"
        case .bootMenu: return "Open the boot menu (restarts)"
        case .rotate180: return "Turn the picture 180\u{00B0}"
        case .displayPower: return "Turn the screen off or on"
        }
    }

    var token: String {
        switch self {
        case .statusScreen: return "board.statusScreen"
        case .wifiSelector: return "board.wifiSelector"
        case .bootMenu: return "board.bootMenu"
        case .rotate180: return "board.rotate180"
        case .displayPower: return "board.displayPower"
        }
    }
}

/// One selectable function for one input: something this Mac does, something
/// the board does on its own, or nothing.
enum InputFunction: Hashable, Sendable {
    case nothing
    case mac(TouchAction)
    case board(BoardFunction)

    var summary: String {
        switch self {
        case .nothing: return "Nothing"
        case .mac(let action): return action.summary
        case .board(let function): return function.summary
        }
    }

    /// What the board is told to do with the input: run its own function,
    /// report it here, or drop it.
    var boardCode: DeviceProtocol.BoardFunctionCode {
        switch self {
        case .nothing: return .nothing
        case .mac: return .sender
        case .board(let function): return function.code
        }
    }

    var needsAccessibility: Bool {
        if case .mac(let action) = self { return action.needsAccessibility }
        return false
    }

    var token: String {
        switch self {
        case .nothing: return "nothing"
        case .mac(let action): return action.token
        case .board(let function): return function.token
        }
    }

    init?(token: String) {
        if token == "nothing" {
            self = .nothing
        } else if let board = (BoardFunction.allCases.first { $0.token == token }) {
            self = .board(board)
        } else if let action = TouchAction(token: token) {
            self = .mac(action)
        } else {
            return nil
        }
    }
}

/// The groups the inputs are listed in, in order.
enum InputGroup: CaseIterable {
    case touch
    case knob
    case bootButton
    case powerButton

    static func of(_ input: DeviceProtocol.TouchGesture) -> InputGroup {
        if input.isTouch { return .touch }
        if input.isKnob { return .knob }
        switch input {
        case .powerKeyPress, .powerKeyLongPress: return .powerButton
        default: return .bootButton
        }
    }

    func title(bootIsKnob: Bool) -> String {
        switch self {
        case .touch: return "Touch"
        case .knob: return "Knob"
        case .bootButton: return bootIsKnob ? "Knob button" : "BOOT button"
        case .powerButton: return "Power button"
        }
    }
}

extension PanelSnapshot {
    /// The inputs this board has, in the order they are listed: what it
    /// reports in EINP, or for firmware that predates that, the touch
    /// gestures its capabilities name and its knob.
    var availableInputs: [DeviceProtocol.TouchGesture] {
        let touchOrder = TouchAction.gestureOrder(landscape: landscape)
        let rest: [DeviceProtocol.TouchGesture] = [
            .knobClockwise, .knobCounterclockwise, .knobPress,
            .bootSinglePress, .bootDoublePress, .bootTriplePress,
            .bootLongPress, .bootExtraLongPress, .powerKeyPress, .powerKeyLongPress,
        ]
        if let report = inputReport {
            return (touchOrder + rest).filter { report.inputs.contains($0) }
        }
        var inputs: [DeviceProtocol.TouchGesture] = []
        if capabilities.contains(.touch) {
            inputs += touchOrder.filter {
                $0 != .longPress || capabilities.contains(.touchLongPress)
            }
        }
        if hasKnob { inputs += [.knobClockwise, .knobCounterclockwise, .knobPress] }
        return inputs
    }

    /// Board functions an input may be given: only on firmware that stores a
    /// map, and only those it says it can run.
    var availableBoardFunctions: [BoardFunction] {
        guard let report = inputReport else { return [] }
        return BoardFunction.allCases.filter { report.functions.contains($0.code) }
    }

    /// What the chosen preset gives `input`. Gestures and the knob follow the
    /// preset; BOOT and the power key keep the board's own defaults, which are
    /// what it did before maps existed.
    func presetFunction(
        for input: DeviceProtocol.TouchGesture, landscape: Bool
    ) -> InputFunction {
        if let action = TouchAction.action(
            for: input, preset: gesturePreset, landscape: landscape) {
            return .mac(action)
        }
        guard !input.isTouch, !input.isKnob,
              let raw = inputReport?.defaultCode(input),
              let code = DeviceProtocol.BoardFunctionCode(rawValue: raw),
              let function = BoardFunction(code: code)
        else { return .nothing }
        return .board(function)
    }

    /// The function `input` runs: the user's own assignment, or the preset's.
    func function(
        for input: DeviceProtocol.TouchGesture, landscape: Bool
    ) -> InputFunction {
        inputAssignments[input] ?? presetFunction(for: input, landscape: landscape)
    }

    /// Whether any assignment differs from the preset.
    var hasCustomAssignments: Bool { !inputAssignments.isEmpty }

    /// The map to send the board, one code per input it names. A gesture
    /// whose meaning turns with the panel (window cycling's long axis) is
    /// reported here in both orientations, so the board never has to know
    /// which way up it is; inputs the board lacks keep its own defaults.
    ///
    /// What a preset leaves unbound keeps the board's default too - for a
    /// gesture that is "report it", so a tap still shows the info bar and an
    /// untouched board is never sent a map. Only an assignment of Nothing
    /// tells the board to drop an input.
    var boardCodes: [DeviceProtocol.TouchGesture: DeviceProtocol.BoardFunctionCode] {
        var codes: [DeviceProtocol.TouchGesture: DeviceProtocol.BoardFunctionCode] = [:]
        for input in DeviceProtocol.TouchGesture.allCases {
            let boardDefault = inputReport?.defaultCode(input)
                .flatMap(DeviceProtocol.BoardFunctionCode.init(rawValue:)) ?? .nothing
            guard inputReport?.inputs.contains(input) == true else {
                // Not on this board now - perhaps only this boot (touch that
                // did not start): left as the board has it, so an assignment
                // made on a good boot is not overwritten.
                codes[input] = inputReport?.current(input)
                    .flatMap(DeviceProtocol.BoardFunctionCode.init(rawValue:)) ?? boardDefault
                continue
            }
            let both = [false, true].map { landscape -> DeviceProtocol.BoardFunctionCode in
                if let assigned = inputAssignments[input] { return assigned.boardCode }
                let preset = presetFunction(for: input, landscape: landscape)
                return preset == .nothing ? boardDefault : preset.boardCode
            }
            if both.contains(.sender) {
                codes[input] = .sender
            } else {
                codes[input] = both.first { $0 != .nothing } ?? .nothing
            }
        }
        return codes
    }

    /// EMAP's flags: the single press (the knob's click on the knob
    /// carrier) given to one of this Mac's functions is counted out on the
    /// board, because a second press would not undo it the way it undoes
    /// mute or the status screen.
    ///
    /// Which input is the single comes from the report (a knob carrier has
    /// the knob's click and no BOOT single), and flag bits a newer board
    /// sent are kept as it has them.
    var boardFlags: UInt8 {
        let unknownBits = (inputReport?.flags ?? 0) & ~DeviceProtocol.inputMapFlagCountPresses
        let knobCarrier = inputReport.map {
            $0.inputs.contains(.knobPress) && !$0.inputs.contains(.bootSinglePress)
        } ?? hasKnob
        let single: DeviceProtocol.TouchGesture = knobCarrier ? .knobPress : .bootSinglePress
        if case .mac = inputAssignments[single] {
            return unknownBits | DeviceProtocol.inputMapFlagCountPresses
        }
        return unknownBits
    }

    /// Whether the board is running the map this app wants it to, for this
    /// app. Only the inputs the board reported are compared, so a shorter
    /// report cannot read as a mismatch forever.
    var boardMapIsCurrent: Bool {
        guard let report = inputReport else { return true }
        return report.mapInForce && report.flags == boardFlags
            && boardCodes.allSatisfy { input, code in
                report.current(input).map { $0 == code.rawValue } ?? true
            }
    }

    /// Whether this app can name every code the board reported. A newer
    /// board may run, or default to, a function this build does not know;
    /// sending it a map would overwrite that with something else, so the map
    /// is left alone until the app is updated.
    var boardMapIsNameable: Bool {
        guard let report = inputReport else { return false }
        return DeviceProtocol.TouchGesture.allCases.allSatisfy { input in
            [report.current(input), report.defaultCode(input)].allSatisfy { code in
                code.map { DeviceProtocol.BoardFunctionCode(rawValue: $0) != nil } ?? true
            }
        }
    }

    /// Whether some input's function posts a synthetic event, which needs
    /// the Accessibility grant.
    var assignmentsNeedAccessibility: Bool {
        availableInputs.contains { input in
            [false, true].contains { function(for: input, landscape: $0).needsAccessibility }
        }
    }
}
