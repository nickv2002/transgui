import XCTest

final class FuzzyMatchTests: XCTestCase {
    func testEmptyQueryMatchesEverythingNeutrally() {
        XCTAssertEqual(FuzzyMatch.score(query: "", candidate: "anything"), 0)
    }

    func testSubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatch.score(query: "ppgrl", candidate: "papergirls"))
    }

    func testNonSubsequenceDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.score(query: "xyz", candidate: "papergirls"))
    }

    func testQueryLongerThanCandidateFails() {
        XCTAssertNil(FuzzyMatch.score(query: "longquery", candidate: "abc"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertNotNil(FuzzyMatch.score(query: "ABC", candidate: "aXbXc"))
    }

    func testContiguousSubstringScoresHigherThanScattered() {
        let contiguous = FuzzyMatch.score(query: "paper", candidate: "papergirls")
        let scattered = FuzzyMatch.score(query: "paper", candidate: "p.a.p.e.r.girls")
        XCTAssertNotNil(contiguous)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(contiguous!, scattered!)
    }

    func testEarlierMatchScoresHigher() {
        let early = FuzzyMatch.score(query: "abc", candidate: "abcdef")
        let late = FuzzyMatch.score(query: "abc", candidate: "zzzzabc")
        XCTAssertNotNil(early)
        XCTAssertNotNil(late)
        XCTAssertGreaterThan(early!, late!)
    }

    func testWordBoundaryBonus() {
        // "tg" should score higher when the chars start words than when buried.
        let boundary = FuzzyMatch.score(query: "tg", candidate: "the great")
        let buried = FuzzyMatch.score(query: "tg", candidate: "atxgx")
        XCTAssertNotNil(boundary)
        XCTAssertNotNil(buried)
        XCTAssertGreaterThan(boundary!, buried!)
    }
}
