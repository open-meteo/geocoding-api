// Portable binary field offsets and record sizes, shared by readers and writers.

enum LocationRecordLayout {
    static let stride = 64
    static let id = 0
    static let latitude = 4
    static let longitude = 8
    static let population = 12
    static let countryID = 16
    static let admin1ID = 20
    static let admin2ID = 24
    static let admin3ID = 28
    static let admin4ID = 32
    static let nameOffset = 36
    static let alternateStart = 40
    static let postcodeStart = 44
    static let elevation = 48
    static let timezone = 50
    static let country = 52
    static let alternateCount = 54
    static let postcodeCount = 56
    static let feature = 58
    static let reserved = 59
}

enum AlternateNameRecordLayout {
    static let stride = 6
    static let languageID = 0
    static let nameOffset = 2
}

enum RadixRootLayout {
    static let stride = 24
    static let indexID = 0
    static let reserved = 2
    static let rootNode = 4
    static let nameBase = 8
    static let nameCount = 12
    static let treeStart = 16
    static let treeLeafBase = 20
}

enum RadixNodeLayout {
    static let terminalFlag: UInt16 = 1
    static let stride = 16
    static let firstEdge = 0
    static let edgeCount = 4
    static let flags = 6
    static let subtreeFirst = 8
    static let subtreeCount = 12
}

enum RadixEdgeLayout {
    static let leafFlag: UInt32 = 0x8000_0000
    static let childMask: UInt32 = 0x7fff_ffff
    static let stride = 12
    static let child = 0
    static let labelOffset = 4
    static let labelLength = 8
    static let firstByte = 10
    static let reserved = 11
}

enum NameMetadataLayout {
    static let stride = 12
    static let postingStart = 0
    static let postingCount = 4
    static let characterCount = 8
    static let reserved = 10
}

enum SearchPostingLayout {
    static let stride = 14
    static let row = 0
    static let rank = 4
    static let country = 8
    static let admin1ID = 10
}

enum AreaBucketLayout {
    static let stride = 28
    static let indexID = 0
    static let reserved = 2
    static let area = 4
    static let entryStart = 8
    static let entryCount = 12
    static let treeStart = 16
    static let treeLeafBase = 20
    static let trailingReserved = 24
}

enum AreaEntryLayout {
    static let stride = 6
    static let nameOrdinal = 0
    static let rankBound = 4
}

enum AdministrativeAliasRecordLayout {
    static let stride = 16
    static let kind = 0
    static let reserved = 1
    static let languageID = 2
    static let nameOffset = 4
    static let candidateStart = 8
    static let candidateCount = 12
    static let trailingReserved = 14
}

enum AdministrativeAliasCandidateLayout {
    static let stride = 8
    static let admin1ID = 0
    static let country = 4
    static let reserved = 6
}

enum AlternateInputLayout {
    static let stride = 20
    static let row = 0
    static let languageID = 4
    static let kind = 6
    static let preference = 7
    static let byteCount = 8
    static let sourceOrder = 12
}

enum SearchCandidateLayout {
    static let stride = 22
    static let indexID = 0
    static let country = 2
    static let admin1ID = 4
    static let row = 8
    static let rank = 12
    static let characterCount = 16
    static let byteCount = 18
}

enum OrdinalViewLayout {
    static let stride = 16
    static let indexID = 0
    static let characterCount = 2
    static let area = 4
    static let nameOrdinal = 8
    static let maximumRank = 12
}
