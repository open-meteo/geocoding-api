import Foundation

/// Optional, request-local counters. Never shared between concurrent searches.
final class SearchDiagnostics: Codable {
    var postingsExamined = 0
    var namesExamined = 0
    var treeNodesVisited = 0
    var postingsRejectedByGeography = 0
    var duplicateHits = 0
    var heapInsertions = 0
    var heapReplacements = 0
    var heapUpdates = 0

    func add(_ other: SearchDiagnostics) {
        postingsExamined += other.postingsExamined
        namesExamined += other.namesExamined
        treeNodesVisited += other.treeNodesVisited
        postingsRejectedByGeography += other.postingsRejectedByGeography
        duplicateHits += other.duplicateHits
        heapInsertions += other.heapInsertions
        heapReplacements += other.heapReplacements
        heapUpdates += other.heapUpdates
    }
}

struct MatchSources: OptionSet, Sendable {
    let rawValue: UInt16
    static let canonical = Self(rawValue: 1 << 0)
    static let localizedAlternate = Self(rawValue: 1 << 1)
    static let commonAlternate = Self(rawValue: 1 << 2)
    static let airportCode = Self(rawValue: 1 << 3)
    static let postcode = Self(rawValue: 1 << 4)
    static let all: Self = [.canonical, .localizedAlternate, .commonAlternate, .airportCode, .postcode]
}

struct SearchHit: Sendable {
    let row: UInt32
    let id: Int32
    var score: Float
    var sources: MatchSources
}

struct NormalizedSearchQuery {
    let text: String
    let characterCount: Int
    let onlyExact: Bool

    init(_ input: String) {
        text = SearchTextNormalizer.foldAndLowercase(input)
        characterCount = text.count
        onlyExact = input.count <= 2
    }
}

/// Version 1 intentionally ignores provenance. Future ranking changes must update
/// both candidate scores and the bound used before pruning, then rebuild the database.
enum SearchScorer {
    static let version: UInt32 = 1
    static let normalizationVersion: UInt32 = 1

    static func boost(characterCount: Int, queryCharacters: Int, isExact: Bool) -> Float {
        isExact ? 1.5 : 1.5 / Float(max(0, characterCount - queryCharacters) + 1)
    }

    static func upperBoost(minimumLength: Int, queryCharacters: Int, onlyExact: Bool) -> Float {
        boost(
            characterCount: max(minimumLength, queryCharacters),
            queryCharacters: queryCharacters,
            isExact: onlyExact || minimumLength <= queryCharacters
        )
    }
}
