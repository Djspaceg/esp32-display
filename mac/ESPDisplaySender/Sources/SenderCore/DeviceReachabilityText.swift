/// What the manager says about a device it cannot reach, or one that is not yet
/// sending. One place, so the wording stays on "device": the boards are
/// devices, and "display" in this app is the Mac's own screen.
enum DeviceReachabilityText {
    /// The session is parked: the device stopped answering on the network.
    static let parked =
        "Not reachable, so capture is stopped for this device. It resumes "
        + "automatically as soon as the device answers again."
    /// Capture paused while the parked session waits for replies.
    static let suspended =
        "The device stopped answering, so mirroring is paused. It resumes by "
        + "itself as soon as the device is back."
    /// Frames wait until the device confirms which board it is.
    static let awaitingIdentity = "Waiting for the device to confirm its identity."
    /// No session exists for this device.
    static let noSession =
        "No session is running for this device, so nothing is being sent."
}
