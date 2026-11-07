import Testing
@testable import FolioCore

@Suite struct MatcherTests {
    let matcher = Matcher()
    let content = "Your BC Hydro bill for the account 12-345. Bank of America statement enclosed."

    @Test func emptyMatchNeverMatches() {
        for algorithm in MatchingAlgorithm.allCases {
            #expect(!matcher.matches(algorithm: algorithm, match: "  ", isInsensitive: true, content: content))
        }
    }

    @Test func noneAndAutoNeverMatch() {
        #expect(!matcher.matches(algorithm: .none, match: "hydro", isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .auto, match: "hydro", isInsensitive: true, content: content))
    }

    @Test func anyWord() {
        #expect(matcher.matches(algorithm: .any, match: "gas hydro", isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .any, match: "gas water", isInsensitive: true, content: content))
        // Word boundaries: "hydr" is not a word in the content.
        #expect(!matcher.matches(algorithm: .any, match: "hydr", isInsensitive: true, content: content))
        // Case sensitivity.
        #expect(!matcher.matches(algorithm: .any, match: "hydro", isInsensitive: false, content: content))
    }

    @Test func anyWordWithQuotedPhrase() {
        let match = "\"Bank of America\" BofA"
        #expect(matcher.matches(algorithm: .any, match: match, isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .any, match: match, isInsensitive: true, content: "Bank of South America"))
        // Whitespace inside quotes is flexible.
        #expect(matcher.matches(algorithm: .any, match: "\"bank   of america\"", isInsensitive: true, content: "bank of\namerica"))
    }

    @Test func allWords() {
        #expect(matcher.matches(algorithm: .all, match: "statement hydro", isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .all, match: "statement water", isInsensitive: true, content: content))
    }

    @Test func literal() {
        #expect(matcher.matches(algorithm: .literal, match: "bc hydro", isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .literal, match: "hydro bc", isInsensitive: true, content: content))
        // Regex metacharacters are escaped.
        #expect(matcher.matches(algorithm: .literal, match: "12-345", isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .literal, match: "12.345", isInsensitive: true, content: content))
    }

    @Test func regex() {
        #expect(matcher.matches(algorithm: .regex, match: "account \\d+-\\d+", isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .regex, match: "account \\d{5}", isInsensitive: true, content: content))
        // Invalid regex does not match and does not crash.
        #expect(!matcher.matches(algorithm: .regex, match: "([", isInsensitive: true, content: content))
    }

    @Test func fuzzy() {
        #expect(matcher.matches(algorithm: .fuzzy, match: "Bank of Amerika", isInsensitive: true, content: content))
        #expect(!matcher.matches(algorithm: .fuzzy, match: "Credit Suisse", isInsensitive: true, content: content))
    }

    @Test func splitMatch() {
        #expect(Matcher.splitMatch("  some random  words \"with   quotes  \" and   spaces") ==
            ["some", "random", "words", "with\\s+quotes", "and", "spaces"])
    }

    @Test func partialRatioMatchesRapidFuzzExamples() throws {
        // fuzz.partial_ratio("this is a test", "this is a test!") == 100
        #expect(Fuzzy.partialRatio("this is a test", "this is a test!") == 100)
        // fuzz.partial_ratio("fuzzy wuzzy was a bear", "wuzzy fuzzy was a bear") ≈ 90.9 (> 90)
        let score = try #require(Fuzzy.partialRatio("fuzzy wuzzy was a bear", "wuzzy fuzzy was a bear"))
        #expect(score > 85)
        #expect(Fuzzy.partialRatio("abc", "xyz", scoreCutoff: 90) == nil)
    }

    @Test func lcsBitParallelAgreesWithDynamicProgramming() {
        let a = Array("kitten sitting on the mat".unicodeScalars.map(\.value))
        let b = Array("sitting kitten on a mat".unicodeScalars.map(\.value))
        let long = Array(String(repeating: "abcdefghij", count: 8).unicodeScalars.map(\.value))
        #expect(Fuzzy.lcsLength(a, b) == Fuzzy.lcsLength(b, a))
        #expect(Fuzzy.lcsLength(long, long) == long.count)
    }
}
