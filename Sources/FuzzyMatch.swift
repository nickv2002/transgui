import Foundation

/// Subsequence ("fuzzy") matching for the search box. A query matches a candidate
/// when every query character appears in the candidate, in order — e.g. `ppgrl`
/// matches "papergirls". A higher score means a better match; `nil` means no match.
///
/// This extends the previous exact-substring filter: a contiguous substring is
/// just the best-scoring kind of subsequence, so plain queries still behave as
/// before but rank above scattered matches.
enum FuzzyMatch {
    /// Score `query` against `candidate`, or `nil` if `query` isn't a subsequence.
    /// Empty queries match everything with a neutral score.
    static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }

        var score = 0
        var qi = 0
        var lastMatch = -1          // index in `c` of the previous matched char
        var prevWasMatch = false    // were we on a matched run?

        var ci = 0
        while ci < c.count, qi < q.count {
            if c[ci] == q[qi] {
                // Reward contiguous runs and matches at word boundaries / start.
                if prevWasMatch { score += 8 }
                if ci == 0 { score += 10 }
                else if Self.isBoundary(before: c[ci - 1]) { score += 6 }

                // Penalise the gap skipped since the previous matched char.
                if lastMatch >= 0 {
                    let gap = ci - lastMatch - 1
                    score -= min(gap, 10)
                }

                lastMatch = ci
                prevWasMatch = true
                qi += 1
            } else {
                prevWasMatch = false
            }
            ci += 1
        }

        guard qi == q.count else { return nil }   // ran out before matching all

        // Prefer matches that start earlier and cover more of a shorter name.
        score -= firstMatchIndex(q, c)
        score -= c.count / 20
        return score
    }

    /// True when `ch` ends a "word", so the next char starts a new one.
    private static func isBoundary(before ch: Character) -> Bool {
        ch == " " || ch == "." || ch == "-" || ch == "_" || ch == "/" || ch == "("
    }

    private static func firstMatchIndex(_ q: [Character], _ c: [Character]) -> Int {
        guard let first = q.first else { return 0 }
        return c.firstIndex(of: first) ?? 0
    }
}
