import XCTest
@testable import Vessel

final class RadarArrivalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func blip(_ id: Int, el: Double, orbit: OrbitClass = .leo) -> RadarBlip {
        RadarBlip(id: id, azimuth: 90, elevation: el, orbit: orbit)
    }

    func testRisenApproachIsFollowed() {
        let f = RadarTracker.follow(expected: [7: now.addingTimeInterval(-5)], arrived: [], visible: [7], now: now)
        XCTAssertEqual(f.arrived, [7])
        XCTAssertNotNil(f.expected[7])
    }

    func testNotYetRisenWaits() {
        let f = RadarTracker.follow(expected: [7: now.addingTimeInterval(30)], arrived: [], visible: [], now: now)
        XCTAssertEqual(f.arrived, [])
        XCTAssertNotNil(f.expected[7])
    }

    func testSetSatelliteIsForgottenSoItsNextApproachCounts() {
        let f = RadarTracker.follow(expected: [7: now.addingTimeInterval(-600)], arrived: [7], visible: [], now: now)
        XCTAssertEqual(f.arrived, [])
        XCTAssertNil(f.expected[7])
    }

    func testArrivalShowsEvenBelowTheLimit() {
        // More high satellites than the plot holds, and one arrival just over the horizon.
        var blips = (1...RadarTracker.maxShown + 5).map { blip($0, el: 40 + Double($0)) }
        blips.append(blip(999, el: 0.4))
        XCTAssertFalse(RadarTracker.passing(blips, filter: nil).contains { $0.id == 999 })
        let view = RadarTracker.inView(blips, filter: nil, arrived: [999])
        XCTAssertEqual(view.last?.id, 999)
        XCTAssertEqual(view.count, RadarTracker.maxShown + 1)
    }

    func testArrivalStillRespectsFilters() {
        let blips = [blip(1, el: 50), blip(2, el: 1, orbit: .meo)]
        XCTAssertEqual(RadarTracker.inView(blips, filter: .leo, arrived: [2]).map(\.id), [1])
        XCTAssertEqual(RadarTracker.inView(blips, filter: nil, arrived: [2]) { $0 != 2 }.map(\.id), [1])
    }
}

final class PinnedCountdownTests: XCTestCase {
    private let aos = Date(timeIntervalSince1970: 2_000_000_000)
    private var pass: PassInfo { PassInfo(aos: aos, los: aos.addingTimeInterval(600), maxElevation: 40, inProgress: false) }

    func testCountsDownBeforeArrival() {
        XCTAssertEqual(RadarPanel.pinnedCountdown(pass, now: aos.addingTimeInterval(-3 * 3600 - 720)), "Arrives in 3h 12m")
    }

    func testSwitchesToLeavingOnceRisen() {
        XCTAssertEqual(RadarPanel.pinnedCountdown(pass, now: aos.addingTimeInterval(1)), "Leaves in 9m 59s")
    }

    func testAfterSettingItWaitsForTheNextPass() {
        XCTAssertTrue(RadarPanel.pinnedCountdown(pass, now: aos.addingTimeInterval(601)).hasPrefix("Left"))
    }

    func testDaysAway() {
        XCTAssertEqual(RadarPanel.span(2 * 86400 + 5 * 3600 + 10), "2d 5h")
        XCTAssertEqual(RadarPanel.span(42), "42s")
    }
}

final class LockHistoryTests: XCTestCase {
    private func entry(_ norad: Int, _ t: TimeInterval) -> LockHistory.Entry {
        .init(norad: norad, name: "SAT \(norad)", countryISO: "US", date: Date(timeIntervalSince1970: t))
    }

    func testNewestFirst() {
        var list: [LockHistory.Entry] = []
        list = LockHistory.adding(entry(1, 1000), to: list)
        list = LockHistory.adding(entry(2, 2000), to: list)
        XCTAssertEqual(list.map(\.norad), [2, 1])
    }

    func testRelockingStraightAwayIsOneVisit() {
        var list = LockHistory.adding(entry(1, 1000), to: [])
        list = LockHistory.adding(entry(1, 1030), to: list)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].date.timeIntervalSince1970, 1030)
        list = LockHistory.adding(entry(1, 5000), to: list)
        XCTAssertEqual(list.count, 2)
    }

    func testCapped() {
        var list: [LockHistory.Entry] = []
        for i in 0..<(LockHistory.limit + 20) { list = LockHistory.adding(entry(i, Double(i) * 1000), to: list) }
        XCTAssertEqual(list.count, LockHistory.limit)
        XCTAssertEqual(list.first?.norad, LockHistory.limit + 19)
    }

    func testGroupedByDay() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let list = [entry(3, 86400 * 2 + 10), entry(2, 86400 + 50), entry(1, 86400 + 10)]
        let days = LockHistory.days(list, calendar: cal)
        XCTAssertEqual(days.map { $0.entries.map(\.norad) }, [[3], [2, 1]])
    }

    func testSurvivesRestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lockhistory-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try MainActor.assumeIsolated {
            let data = try JSONEncoder.iso.encode([entry(5, 1_700_000_000)])
            try data.write(to: file)
            let h = LockHistory(file: file)
            XCTAssertEqual(h.entries.map(\.norad), [5])
            h.clear()
            XCTAssertEqual(LockHistory(file: file).entries.count, 0)
        }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

final class RadarArrivalCapTests: XCTestCase {
    func testOnlyTheLatestArrivalsAreKept() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var expected: [Int: Date] = [:]
        for i in 0..<20 { expected[i] = now.addingTimeInterval(-Double(20 - i)) }
        let f = RadarTracker.follow(expected: expected, arrived: [], visible: Set(0..<20), now: now)
        XCTAssertEqual(f.arrived, Set((20 - RadarTracker.maxArrivals)..<20))
    }
}

final class LockedPathTests: XCTestCase {
    func testTravelledFraction() {
        let aos = Date(timeIntervalSince1970: 1000)
        let p = SatPass(aos: aos, los: aos.addingTimeInterval(600), peak: aos.addingTimeInterval(300), maxElevation: 40,
                        track: [.init(az: 0, el: 0), .init(az: 90, el: 40), .init(az: 180, el: 0)])
        XCTAssertEqual(RadarScope.travelled(p, at: aos.addingTimeInterval(-50)), 0)
        XCTAssertEqual(RadarScope.travelled(p, at: aos.addingTimeInterval(150)), 0.25, accuracy: 1e-9)
        XCTAssertEqual(RadarScope.travelled(p, at: aos.addingTimeInterval(900)), 1)
    }
}
