import SenderProtocol

extension PanelSnapshot {
    /// Whether this board has a knob, known from the profile it already
    /// reports (its mDNS record or USB identity) looked up in the shipped
    /// board descriptors, or from a knob gesture it sent. False until the
    /// board has shown either.
    var hasKnob: Bool {
        knobReported
            || profile.map { GeneratedBoardCatalog.encoderProfiles.contains($0) } ?? false
    }

    /// Whether this panel's page should offer the way to the Accessibility
    /// grant media keys need. A knob is a volume knob under every preset; the
    /// glass sends media keys only under multimedia, and only if it has one.
    func offersMediaKeyGrant(authorized: Bool) -> Bool {
        !authorized && (hasKnob
            || (gesturePreset == .multimedia && capabilities.contains(.touch)))
    }
}
