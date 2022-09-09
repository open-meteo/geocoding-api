import Foundation
import Vapor


extension GeocodingDatabase {
    static let geonamesFile = URL(fileURLWithPath: "data/allCountries.txt")
    static let alternateNamesFiles = URL(fileURLWithPath: "data/alternateNames.txt")
    static let databaseFile = URL(fileURLWithPath: "data/database.bin")
    
    /// Read geonames txt files and create an index protobuf file
    public static func createDatabase(logger: Logger) throws {
        logger.info("Create new geocoding database")
        let alternativeNamesData = try Data(contentsOf: alternateNamesFiles, options: [.mappedIfSafe, .uncached])
        let alternate = AlternateNames(data: alternativeNamesData, logger: logger)
        
        let geonamesData = try Data(contentsOf: geonamesFile, options: [.mappedIfSafe, .uncached])
        let geonames = GeocodingDatabase.Geonames(data: geonamesData, alternativeNames: alternate, logger: logger)
        
        let searchTree = GeocodingDatabase(geonames: geonames, logger: logger)
        let data: Data = try searchTree.serializedData()
        let start = Date()
        logger.info("Write database to disk")
        try data.write(to: databaseFile)
        logger.info("Database written in \(Date().timeIntervalSince(start)) seconds, size \(ByteCountFormatter().string(fromByteCount: Int64(data.count)))")
    }
    
    public static func loadOrCreate(logger: Logger) throws -> GeocodingDatabase {
        if !FileManager.default.fileExists(atPath: databaseFile.path) {
            try Self.createDatabase(logger: logger)
        }
        let start = Date()
        logger.info("Load existing database")
        let data = try Data(contentsOf: URL(fileURLWithPath: "data/database.bin"), options: [.mappedIfSafe, .uncached])
        let searchTree = try GeocodingDatabase(serializedData: data)
        logger.info("Finished loading in \(Date().timeIntervalSince(start)) seconds, \(searchTree.geonames.geonames.count) entries")
        return searchTree
    }
    
    /// Search for a string in the indexed location names and one language index
    public func search(_ searchString: String, languageId: Int32, maxCount: Int) -> [(Int32, Float)] {
        let stripped = searchString.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        let results = PriorityQueue(length: maxCount)
        let onlyExact = searchString.count <= 2
        index.search(Substring(stripped), results: results, onlyExact: onlyExact, geonames: geonames.geonames)
        languageIndex[Int(languageId)].search(Substring(stripped), results: results, onlyExact: onlyExact, geonames: geonames.geonames)
        return results.queue.filter({$0.id > 0})
    }
    
    /// Search for a string in the indexed location names and one language index
    public func proximity(latitude: Float, longitude: Float, maxCount: Int, maxDistanceKilometer: Float) -> [(Int32, Float)] {
        let results = geotree.knn(latitude: latitude, longitude: longitude, count: maxCount, maxDistanceKilometer: maxDistanceKilometer, elements: geonames.geonames)
        return results.filter({$0.id > 0})
    }

    public init(geonames: Geonames, logger: Logger) {
        logger.info("GeoTree: Start loading")
        let startTree = Date()
        self.geotree = GeoTree(elements: geonames.geonames, depth: nil)
        logger.info("GeoTree: Finished loading in \(Date().timeIntervalSince(startTree)) seconds")
        
        let start = Date()
        logger.info("SearchTree: Start loading")
        
        self.geonames = geonames
        var languageIndex = [SearchTreeLoader]()
        languageIndex.reserveCapacity(geonames.languages.count)
        for _ in geonames.languages {
            languageIndex.append(SearchTreeLoader())
        }
        let languageEmpty = geonames.languages.firstIndex(where: {$0 == ""})!
        let languageIata = geonames.languages.firstIndex(where: {$0 == "icao"})!
        let languageIcao = geonames.languages.firstIndex(where: {$0 == "iata"})!
        
        logger.info("SearchTree: Prepare language trees")
        for (id, geoname) in geonames.geonames {
            if !geonames.includeInSearchIndex(featureCode: geoname.featureCode) {
                continue
            }
            for name in geoname.alternativeNames {
                if name.0 == languageEmpty {
                    continue
                }
                languageIndex[Int(name.0)].add(name.1, id: id)
            }
        }
        self.languageIndex = languageIndex.map({$0.immutable()})
        
        logger.info("SearchTree: Load main index")
        let index = SearchTreeLoader()
        for (id, geoname) in geonames.geonames {
            if !geonames.includeInSearchIndex(featureCode: geoname.featureCode) {
                continue
            }
            index.add(geoname.name, id: id)
            for name in geoname.alternativeNames {
                if name.0 == languageEmpty || name.0 == languageIata || name.0 == languageIcao {
                    index.add(name.1, id: id)
                }
            }
            for name in geoname.postcodes {
                index.add(name, id: id)
            }
        }
        self.index = index.immutable()
        
        logger.info("SearchTree: Finished loading in \(Date().timeIntervalSince(start)) seconds")
    }
}
