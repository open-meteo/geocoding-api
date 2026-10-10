import Foundation

enum AdministrativeAliasKind: UInt8, CaseIterable, Hashable {
    case common
    case localized
    case abbreviation
}

enum AdministrativeAliasIndexLayout {
    static let recordStride = AdministrativeAliasRecordLayout.stride
    static let candidateStride = AdministrativeAliasCandidateLayout.stride
}
