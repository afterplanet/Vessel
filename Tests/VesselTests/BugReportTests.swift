import XCTest
@testable import Vessel

final class BugReportTests: XCTestCase {
    private let details = BugReport.Details(appVersion: "1.0.1 (7)", macOS: "27.2.0", model: "Mac16,1, Apple M4",
                                            receiver: "RTL-SDR", satellite: "ISS (ZARYA)")

    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testOpensTheRepositoryNewIssuePage() {
        let (url, trimmed) = BugReport.issueURL(title: " Waterfall freezes ", description: "It stops.", details: details, imageCount: 0)
        XCTAssertFalse(trimmed)
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/afterplanet/Vessel/issues/new")
        let q = query(url)
        XCTAssertEqual(q["title"], "Waterfall freezes")
        XCTAssertEqual(q["labels"], "bug")
        XCTAssertTrue(q["body"]!.hasPrefix("It stops."))
        XCTAssertTrue(q["body"]!.contains("- Vessel 1.0.1 (7)"))
        XCTAssertTrue(q["body"]!.contains("- Locked satellite: ISS (ZARYA)"))
    }

    /// Characters that mean something in an address must arrive as typed.
    func testSpecialCharactersSurvive() {
        let text = "Gain +5 & PPM 3 #2\nline two: 100% ✓ 日本"
        let (url, _) = BugReport.issueURL(title: "A+B & C?", description: text, details: nil, imageCount: 0)
        let q = query(url)
        XCTAssertEqual(q["title"], "A+B & C?")
        XCTAssertTrue(q["body"]!.hasPrefix(text))
        XCTAssertFalse(q["body"]!.contains("### System"), "left out when unticked")
    }

    func testLongDescriptionsAreTrimmedToFit() {
        let long = String(repeating: "The spectrum stops updating after the pass ends. ", count: 400)
        let (url, trimmed) = BugReport.issueURL(title: "Long", description: long, details: details, imageCount: 2)
        XCTAssertTrue(trimmed)
        XCTAssertLessThanOrEqual(url.absoluteString.count, BugReport.maxURLLength)
        let body = query(url)["body"]!
        XCTAssertTrue(body.contains("…"))
        XCTAssertTrue(body.contains("### System"), "system details are kept when the text is cut")
        XCTAssertTrue(body.contains("2 images to paste"))
    }

    func testOnlyTheListedDetailsAreSent() {
        let d = BugReport.currentDetails(receiver: nil, satellite: nil)
        XCTAssertEqual(d.lines.count, 3)
        XCTAssertTrue(d.lines[1].hasPrefix("macOS "))
        let body = BugReport.body(description: "x", details: d, imageCount: 0)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertFalse(body.contains(home), "no file paths")
        if let call = UserDefaults.standard.string(forKey: "tx.callsign"), !call.isEmpty {
            XCTAssertFalse(body.contains(call), "no callsign")
        }
    }

    func testImagesAreStagedWithPlainNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bug-src-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("Screenshot 2026-11-12 at 10.00.PNG")
        let b = dir.appendingPathComponent("photo.jpg")
        try Data([1]).write(to: a); try Data([2]).write(to: b)
        let staged = BugReport.stage([a, b])
        XCTAssertEqual(staged.map(\.lastPathComponent), ["image-1.png", "image-2.jpg"])
        XCTAssertTrue(staged.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertTrue(BugReport.isImage(a))
        XCTAssertFalse(BugReport.isImage(dir.appendingPathComponent("notes.txt")))
        try? FileManager.default.removeItem(at: staged[0].deletingLastPathComponent())
    }
}
