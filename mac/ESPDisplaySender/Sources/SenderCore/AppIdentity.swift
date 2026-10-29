import Foundation

/// The application identity shared by every app-owned macOS resource.
///
/// Keep the configured identifier in one place. Derived identifiers must use
/// these values rather than reproducing the configured string, so an identity
/// move updates permissions, extensions, audio, Keychain storage, and logs
/// together.
enum AppIdentity {
    static let bundleIdentifier = "com.resourcefork.espdisplay"
    static let displayName = "ESPDisplay"

    static let cameraExtensionBundleIdentifier = bundleIdentifier + ".camera-extension"
    static let audioDriverBundleIdentifier = bundleIdentifier + ".audio-driver"
    static let credentialsService = bundleIdentifier + ".credentials"
    static let keychainAccessGroup = "4D22XL743H." + bundleIdentifier
    static let audioDeviceUIDPrefix = bundleIdentifier + ".display."
    static let systemAudioTapUIDPrefix = bundleIdentifier + ".system-audio-tap."
    static let savedNetworkPasteboardType = bundleIdentifier + ".saved-network-row"

    static func notification(_ suffix: String) -> String {
        bundleIdentifier + "." + suffix
    }
}
