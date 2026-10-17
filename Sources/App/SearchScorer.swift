import Foundation

struct SearchHit: Sendable {
    let row: UInt32
    let id: Int32
    var score: Float
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

/// Ranking changes must update
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
