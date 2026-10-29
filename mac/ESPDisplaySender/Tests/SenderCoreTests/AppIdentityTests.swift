import Foundation
import XCTest

@testable import SenderCore

final class AppIdentityTests: XCTestCase {
    func testApplicationIdentifierHasOneSwiftDefinition() throws {
        let identifier = "com.resourcefork.espdisplay"
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macRoot = packageRoot.deletingLastPathComponent()
        let sourceRoots = [
            packageRoot.appendingPathComponent("Sources", isDirectory: true),
            macRoot.appendingPathComponent("CameraExtension", isDirectory: true),
        ]
        let sourceFiles = sourceRoots.flatMap { root in
            FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil
            )?.compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" } ?? []
        }
        let offenders = try sourceFiles
            .filter { $0.lastPathComponent != "AppIdentity.swift" }
            .filter { try String(contentsOf: $0, encoding: .utf8).contains(identifier) }
            .map(\.path)
            .sorted()

        XCTAssertEqual(offenders, [])
    }
}
