import CoreFoundation
import XCTest

@testable import SenderCore

/// TCCAccessRequest keeps the answer block and calls it later, once the user
/// answers the prompt. Build 355 handed it a non-escaping block, so Swift's
/// escape check trapped the moment the call returned: the app crashed on the
/// first launch that asked for System Audio Recording. These stand-ins keep
/// the block exactly as TCC does.
final class TCCAudioCaptureTests: XCTestCase {
    func testTheRequestAnswerMayArriveAfterTheCallReturns() {
        let answered = expectation(description: "answer")
        let result = AnswerBox()
        TCCAudioCaptureTests.answer = { _ in }
        let capture = TCCAudioCapture(
            preflight: unsafeBitCast(tccPreflight, to: UnsafeMutableRawPointer.self),
            request: unsafeBitCast(tccRequestLater, to: UnsafeMutableRawPointer.self))
        capture.request { allowed in
            result.value = allowed
            answered.fulfill()
        }
        // The prompt is answered after request() has returned.
        TCCAudioCaptureTests.answerLater(true)
        wait(for: [answered], timeout: 2)
        XCTAssertEqual(result.value, true)
        XCTAssertEqual(capture.preflight(), .notDetermined)
    }

    nonisolated(unsafe) static var answer: (@convention(block) (Bool) -> Void)?

    static func answerLater(_ allowed: Bool) {
        let block = answer
        answer = nil
        block?(allowed)
    }
}

private final class AnswerBox: @unchecked Sendable {
    var value: Bool?
}

private let tccPreflight: @convention(c) (CFString, CFDictionary?) -> Int32 = { _, _ in 2 }

/// Keeps the block, as TCCAccessRequest does, and answers later.
private let tccRequestLater: @convention(c) (
    CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void
) -> Void = { _, _, block in
    TCCAudioCaptureTests.answer = block
}
