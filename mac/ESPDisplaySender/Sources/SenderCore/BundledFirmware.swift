import Foundation
import SenderProtocol

/// The firmware bundle the app ships with.
///
/// WHY THE APP CARRIES ONE AT ALL, since the over-the-air sheet asks the user for a
/// file. A `.espdispfw` can only come from `tools/espdisp.py bundle`, so a path
/// that requires the user to supply one requires the user to open a terminal - and
/// the whole point of onboarding a blank board from the app is that they do not
/// have to. For an update that is a reasonable ask, because anyone updating already
/// has a panel working; for a board straight out of its box it is the difference
/// between working and not.
///
/// SO `mac/make-app.sh` BUILDS ONE AT PACKAGING TIME and the Xcode build copies it
/// into Resources. That does use the CLI, on the machine of whoever packages the
/// app, which is not what the requirement is about.
///
/// TWO COSTS, both real and neither hidden:
///
///   - The app grows by the bundle, about 2.3MB today for both boards.
///   - The firmware in it is fixed when the app is packaged, so an app installed
///     six months ago writes six-month-old firmware. The board can be updated over
///     the air immediately afterwards, and the README says so.
///
/// A build with no bundle is normal rather than broken: `swift build` produces no
/// app wrapper and therefore no Resources, and the packaging step can be skipped
/// deliberately. `UsbOnboardingPlan.chooseBundle` is the case for it, and picking a
/// file by hand still works.
enum BundledFirmware {
    /// The resource name make-app.sh writes. Fixed rather than globbed so that
    /// what the app looks for and what the script installs are one string in one
    /// place - and so a second file left in Resources cannot change which firmware
    /// a board gets.
    static let resourceName = "espdisp-default"

    /// What the app has to offer.
    enum Availability: Equatable {
        /// Packaged without one.
        case none
        /// There is a file and it could not be read. Kept distinct from `none`
        /// because a corrupt shipped bundle is a packaging fault and should not
        /// read as "this app does not do that".
        case unreadable(path: String, reason: String)
        case ready(FirmwareBundle, url: URL)
    }

    static func defaultBundleURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: resourceName, withExtension: FirmwareBundle.fileExtension)
    }

    static func load(in bundle: Bundle = .main) -> Availability {
        guard let url = defaultBundleURL(in: bundle) else { return .none }
        do {
            return .ready(try FirmwareBundle.read(contentsOf: url), url: url)
        } catch {
            return .unreadable(
                path: url.lastPathComponent, reason: error.localizedDescription)
        }
    }
}
