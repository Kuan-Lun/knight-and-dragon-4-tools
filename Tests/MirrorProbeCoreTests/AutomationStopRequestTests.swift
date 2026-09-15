import Foundation
import XCTest
@testable import MirrorProbeCore

final class AutomationStopRequestTests: XCTestCase {
    func testNormalQuitStopsCommandsWithoutAStopFileAndRemainsLatched() {
        let request = AutomationStopRequest()
        XCTAssertFalse(request.isRequested(stopFileURL: nil))

        XCTAssertTrue(request.requestApplicationQuit())
        XCTAssertTrue(request.isRequested(stopFileURL: nil))
        XCTAssertEqual(request.reportReason, "applicationQuitRequested")
        XCTAssertFalse(request.requestApplicationQuit())
        XCTAssertTrue(request.isRequested(stopFileURL: nil))
    }

    func testStopFileStillWorksWithoutQuitAndIsNotModifiedByQuit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "mirror-probe-stop-request-tests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stopURL = directory.appendingPathComponent("STOP")
        let request = AutomationStopRequest()
        XCTAssertFalse(request.isRequested(stopFileURL: stopURL))

        let content = Data("user stop".utf8)
        try content.write(to: stopURL)
        XCTAssertTrue(request.isRequested(stopFileURL: stopURL))
        XCTAssertEqual(request.reportReason, "stopFileDetected")
        request.requestApplicationQuit()
        XCTAssertEqual(try Data(contentsOf: stopURL), content)

        try FileManager.default.removeItem(at: stopURL)
        XCTAssertTrue(request.isRequested(stopFileURL: stopURL))
        XCTAssertEqual(request.reportReason, "applicationQuitRequested")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopURL.path))
    }
}
