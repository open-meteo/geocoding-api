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

/// Runtime bonus changes must keep candidate scores and pruning bounds consistent.
/// Changes to stored ranks or their interpretation also require a version bump and rebuild.
enum SearchScorer {
    static let version: UInt32 = 2
    static let normalizationVersion: UInt32 = 1

    static func boost(characterCount: Int, queryCharacters: Int, isExact: Bool) -> Float {
        // Ten unmatched characters halve the bonus, allowing important places with
        // longer names to compete with smaller places that match exactly.
        isExact ? 1.5 : 1.5 / (1 + 0.1 * Float(max(0, characterCount - queryCharacters)))
    }

    static func upperBoost(minimumLength: Int, queryCharacters: Int, onlyExact: Bool) -> Float {
        boost(
            characterCount: max(minimumLength, queryCharacters),
            queryCharacters: queryCharacters,
            isExact: onlyExact || minimumLength <= queryCharacters
        )
    }
}
