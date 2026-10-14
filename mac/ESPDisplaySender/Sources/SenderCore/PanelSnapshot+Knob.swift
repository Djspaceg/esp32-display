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
    /// grant media keys and recorded key presses need: whenever one of its
    /// inputs is given one, which a knob is under every preset.
    func offersMediaKeyGrant(authorized: Bool) -> Bool {
        !authorized && (hasKnob || assignmentsNeedAccessibility)
    }
}
