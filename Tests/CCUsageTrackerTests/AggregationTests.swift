import XCTest
@testable import CCUsageCore

final class AggregationTests: XCTestCase {
    // SessionSnapshot(window:value:) is a tiny test helper built inline below.
    func snap(_ pct5: Double?, _ rst5: Double?,
              _ pctW: Double?, _ rstW: Double?,
              updatedAt: Double, id: String) -> SessionSnapshot {
        func win(_ p: Double?, _ r: Double?) -> SessionSnapshot.Window? {
            (p == nil && r == nil) ? nil
                : .init(used_percentage: p, resets_at: r)
        }
        return SessionSnapshot(
            updated_at: updatedAt,
            model: "claude-test",
            session_id: id,
            five_hour: win(pct5, rst5),
            seven_day: win(pctW, rstW)
        )
    }

    func testMaxPercentageWinsWithinSameResetWindow() {
        let snaps = [
            snap(55, 1000, 21, 2000, updatedAt: 10, id: "A"),
            snap(75, 1000, 23, 2000, updatedAt: 11, id: "B"),
            snap(92, 1000, 25, 2000, updatedAt: 12, id: "C")
        ]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 92)
        XCTAssertEqual(agg?.fiveHour.resetsAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(agg?.sevenDay.usedPercentage, 25)
    }

    func testNewerResetWindowReplacesEvenWhenLower() {
        let snaps = [
            snap(92, 1000, 25, 2000, updatedAt: 10, id: "A"),
            snap(4, 2000, 5, 4000, updatedAt: 11, id: "B")  // newer window
        ]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 4)
        XCTAssertEqual(agg?.fiveHour.resetsAt, Date(timeIntervalSince1970: 2000))
        XCTAssertEqual(agg?.sevenDay.usedPercentage, 5)
    }

    func testArbitraryOrderKeepsMaxWithinWindow() {
        let snaps = [
            snap(92, 1000, nil, nil, updatedAt: 1, id: "C"),
            snap(30, 1000, nil, nil, updatedAt: 2, id: "A"),
            snap(70, 1000, nil, nil, updatedAt: 3, id: "B")
        ]
        XCTAssertEqual(ClaudeUsageCore.aggregate(snapshots: snaps)?.fiveHour.usedPercentage, 92)
    }

    func testWindowsAggregatedIndependently() {
        // five_hour present in A only; seven_day present in B only.
        let snaps = [
            snap(55, 1000, nil, nil, updatedAt: 10, id: "A"),
            snap(nil, nil, 30, 2000, updatedAt: 11, id: "B")
        ]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 55)
        XCTAssertEqual(agg?.sevenDay.usedPercentage, 30)
    }

    func testOneWindowAbsentFromAllPayloads() {
        let snaps = [snap(55, 1000, nil, nil, updatedAt: 10, id: "A")]
        let agg = ClaudeUsageCore.aggregate(snapshots: snaps)
        XCTAssertEqual(agg?.fiveHour.usedPercentage, 55)
        XCTAssertNil(agg?.sevenDay.usedPercentage)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ClaudeUsageCore.aggregate(snapshots: []))
    }

    func testNoWindowDataReturnsNil() {
        let snaps = [snap(nil, nil, nil, nil, updatedAt: 10, id: "A")]
        XCTAssertNil(ClaudeUsageCore.aggregate(snapshots: snaps))
    }

    func testUpdatedAtIsMaxAcrossSnapshots() {
        let snaps = [
            snap(55, 1000, nil, nil, updatedAt: 10, id: "A"),
            snap(60, 1000, nil, nil, updatedAt: 30, id: "B"),
            snap(58, 1000, nil, nil, updatedAt: 20, id: "C")
        ]
        XCTAssertEqual(ClaudeUsageCore.aggregate(snapshots: snaps)?.updatedAt,
                       Date(timeIntervalSince1970: 30))
    }
}