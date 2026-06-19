import XCTest

final class FormattersTests: XCTestCase {
    func testSizeNonNegative() {
        XCTAssertFalse(Formatters.size(0).isEmpty)
        XCTAssertTrue(Formatters.size(1_048_576).contains("MB"))
        // Negative byte counts are clamped to zero, never rendered as "-".
        XCTAssertFalse(Formatters.size(-100).contains("-"))
    }

    func testSpeedBlankWhenZero() {
        XCTAssertEqual(Formatters.speed(0), "")
        XCTAssertEqual(Formatters.speed(-5), "")
    }

    func testSpeedHasPerSecondSuffix() {
        XCTAssertTrue(Formatters.speed(1_048_576).hasSuffix("/s"))
    }

    func testPercentClamped() {
        XCTAssertEqual(Formatters.percent(0), "0%")
        XCTAssertEqual(Formatters.percent(0.5), "50%")
        XCTAssertEqual(Formatters.percent(1), "100%")
        XCTAssertEqual(Formatters.percent(1.5), "100%")
        XCTAssertEqual(Formatters.percent(-1), "0%")
    }

    func testRatio() {
        XCTAssertEqual(Formatters.ratio(1.5), "1.50")
        XCTAssertEqual(Formatters.ratio(0), "0.00")
        XCTAssertEqual(Formatters.ratio(-1), "∞")
    }

    func testEtaSpecialValues() {
        XCTAssertEqual(Formatters.eta(-1), "∞")
        XCTAssertEqual(Formatters.eta(-2), "")
        XCTAssertEqual(Formatters.eta(0), "Done")
    }

    func testEtaDurations() {
        XCTAssertEqual(Formatters.eta(45), "45s")
        XCTAssertEqual(Formatters.eta(90), "1m 30s")
        XCTAssertEqual(Formatters.eta(3_600), "1h 0m")
        XCTAssertEqual(Formatters.eta(90_000), "1d 1h")
    }

    func testDatesEmptyForNonPositiveEpoch() {
        XCTAssertEqual(Formatters.compactDate(0), "—")
        XCTAssertEqual(Formatters.compactDateTime(0), "—")
        XCTAssertEqual(Formatters.date(0), "—")
        XCTAssertEqual(Formatters.dateTime(-1), "—")
    }

    func testDatesNonEmptyForRealEpoch() {
        let epoch = 1_700_000_000.0
        XCTAssertNotEqual(Formatters.compactDate(epoch), "—")
        XCTAssertNotEqual(Formatters.date(epoch), "—")
        // compactDateTime joins date + time with a plain space (no locale comma).
        XCTAssertFalse(Formatters.compactDateTime(epoch).contains(","))
    }
}
