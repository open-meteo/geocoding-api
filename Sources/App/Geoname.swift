import Foundation
import Vapor


/**
 Loads the main geonames table.
 
 Fields timezones, featureCodes and countryIso2 are highly redundant the kept in separat arrays to reduce memory.
 
 Admin codes 1 to 4 are hashed and kept as a lookup table to the representative geonameid
 */
extension GeocodingDatabase.Geonames {
    /**
     The main 'geoname' table has the following fields :
     ---------------------------------------------------
     0. geonameid         : integer id of record in geonames database
     1. name              : name of geographical point (utf8) varchar(200)
     2. asciiname         : name of geographical point in plain ascii characters, varchar(200)
     3. alternatenames    : alternatenames, comma separated, ascii names automatically transliterated, convenience attribute from alternatename table, varchar(10000)
     4. latitude          : latitude in decimal degrees (wgs84)
     5. longitude         : longitude in decimal degrees (wgs84)
     6. feature class     : see http://www.geonames.org/export/codes.html, char(1)
     7. feature code      : see http://www.geonames.org/export/codes.html, varchar(10)
     8. country code      : ISO-3166 2-letter country code, 2 characters
     9. cc2               : alternate country codes, comma separated, ISO-3166 2-letter country code, 200 characters
     10. admin1 code       : fipscode (subject to change to iso code), see exceptions below, see file admin1Codes.txt for display names of this code; varchar(20)
     11. admin2 code       : code for the second administrative division, a county in the US, see file admin2Codes.txt; varchar(80)
     12. admin3 code       : code for third level administrative division, varchar(20)
     13. admin4 code       : code for fourth level administrative division, varchar(20)
     14. population        : bigint (8 byte int)
     15. elevation         : in meters, integer
     16. dem               : digital elevation model, srtm3 or gtopo30, average elevation of 3''x3'' (ca 90mx90m) or 30''x30'' (ca 900mx900m) area in meters, integer. srtm processed by cgiar/ciat.
     17. timezone          : the iana timezone id (see file timeZone.txt) varchar(40)
     18. modification date : date of last modification in yyyy-MM-dd format
     */
    init(data: Data, alternativeNames: AlternateNames, logger: Logger) {
        let start = Date()
        logger.info("Geonames: Start loading")
        
        var timeszones = DeduplicatedStrings<Int32>()
        //var featureCodes = DeduplicatedStrings<Int32>()
        //var countryIso2 = DeduplicatedStrings<Int32>()
        var geonames = [Int32: GeocodingDatabase.Geoname]()
        
        var admin1ToGeonameId = [Int: Int32]()
        var admin2ToGeonameId = [Int: Int32]()
        var admin3ToGeonameId = [Int: Int32]()
        var admin4ToGeonameId = [Int: Int32]()
        var countries = [String: Int32]()
        
        let tab = Character("\t").asciiValue!
        
        /// first pass, look for admin areas and count how many geonames we are about to index
        var count = 0
        data.forEachLine { line in
            if line.isEmpty {
                return
            }
            var offset = 0
            let positionGeonameid = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset)
            let positionFeatureCode = line.seekUntil(value: tab, offset: &offset)
            let positionCountryCode = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset) // positionCC2
            let positionAdmin1 = line.seekUntil(value: tab, offset: &offset)
            let positionAdmin2 = line.seekUntil(value: tab, offset: &offset)
            let positionAdmin3 = line.seekUntil(value: tab, offset: &offset)
            let positionAdmin4 = line.seekUntil(value: tab, offset: &offset)
            
            let featureCode = positionFeatureCode.string
            if !Self.includeGeoname(featureCode: featureCode) {
                return
            }
            
            count += 1
            
            let geonameid = positionGeonameid.asciiToInt32
            
            
            // If the geoname is a administrative area, store the reference
            if featureCode == "ADM1" {
                let admin1Hash = positionCountryCode.extendUntil(positionAdmin1).hashValue
                admin1ToGeonameId[admin1Hash] = geonameid
            }
            if featureCode == "ADM2" {
                let admin2Hash = positionCountryCode.extendUntil(positionAdmin2).hashValue
                admin2ToGeonameId[admin2Hash] = geonameid
            }
            if featureCode == "ADM3" {
                let admin3Hash = positionCountryCode.extendUntil(positionAdmin3).hashValue
                admin3ToGeonameId[admin3Hash] = geonameid
            }
            if featureCode == "ADM4" {
                let admin4Hash = positionCountryCode.extendUntil(positionAdmin4).hashValue
                admin4ToGeonameId[admin4Hash] = geonameid
            }
            if featureCode == "PCLI" {
                countries[positionCountryCode.string] = geonameid
            }
        }
        
        logger.info("Geonames: Reserving memory for \(count) entries")
        geonames.reserveCapacity(count)
        logger.info("Geonames: Start reading")
        
        data.forEachLine { line in
            if line.isEmpty {
                return
            }
            var offset = 0
            let positionGeonameid = line.seekUntil(value: tab, offset: &offset)
            let positionName = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset) // positionAsciiname
            let _ = line.seekUntil(value: tab, offset: &offset) // positionAlterenateName
            let positionLatitude = line.seekUntil(value: tab, offset: &offset)
            let positionLongitude = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset) // positionFeatureClass
            let positionFeatureCode = line.seekUntil(value: tab, offset: &offset)
            let positionCountryCode = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset) // positionCC2
            let positionAdmin1 = line.seekUntil(value: tab, offset: &offset)
            let positionAdmin2 = line.seekUntil(value: tab, offset: &offset)
            let positionAdmin3 = line.seekUntil(value: tab, offset: &offset)
            let positionAdmin4 = line.seekUntil(value: tab, offset: &offset)
            let positionPopulation = line.seekUntil(value: tab, offset: &offset)
            let positionElevation = line.seekUntil(value: tab, offset: &offset)
            let positionDEM = line.seekUntil(value: tab, offset: &offset)
            let positionTimezone = line.seekUntil(value: tab, offset: &offset)
            
            let featureCode = positionFeatureCode.string
            if !Self.includeGeoname(featureCode: featureCode) {
                return
            }
            
            let geonameid = positionGeonameid.asciiToInt32
            let name = positionName.string
        
            let latitude = Float(positionLatitude.string)!
            let longitude = Float(positionLongitude.string)!
            //let featureClass = line[positionLongitude ..< positionFeatureClass].first ?? 0
            let countryCode = positionCountryCode.string
            /// We do not need the actual value, just a hash to test if it is equal is fine
            
            let admin1 = admin1ToGeonameId[positionCountryCode.extendUntil(positionAdmin1).hashValue] ?? 0
            let admin2 = admin2ToGeonameId[positionCountryCode.extendUntil(positionAdmin2).hashValue] ?? 0
            let admin3 = admin3ToGeonameId[positionCountryCode.extendUntil(positionAdmin3).hashValue] ?? 0
            let admin4 = admin4ToGeonameId[positionCountryCode.extendUntil(positionAdmin4).hashValue] ?? 0
            let countryID = countries[countryCode] ?? 0
            
            let population = positionPopulation.asciiToUInt32
            let elevation = positionElevation.isEmpty ? positionDEM.asciiToInt16 : positionElevation.asciiToInt16
            let timezone = positionTimezone
        
            
            var ranking = Self.populationToRank(population)
            let postcodes = alternativeNames.postcodes[geonameid] ?? []

            if postcodes.count > 0 {
                ranking += 0.1
            }
            if featureCode == "PPL" {
                ranking += 0.1
            }
            if featureCode == "PPLA" || featureCode == "PPLC" {
                ranking += 0.3
            }
            if featureCode == "PPLA2" {
                ranking += 0.23
            }
            if featureCode == "PPLA3" {
                ranking += 0.2
            }
            if featureCode == "PPLA4" {
                ranking += 0.18
            }
            if featureCode == "PPLA5" {
                ranking += 0.15
            }
            var g = GeocodingDatabase.Geoname()
            g.id = geonameid
            g.name = name
            g.latitude = latitude
            g.longitude = longitude
            g.ranking = ranking
            g.elevation = Float(elevation)
            g.featureCode = featureCode
            g.countryIso2 = countryCode
            g.admin1ID = admin1
            g.admin2ID = admin2
            g.admin3ID = admin3
            g.admin4ID = admin4
            g.countryID = countryID
            g.timezoneIndex = timeszones.findOrAppend(timezone)
            g.population = population
            g.alternativeNames = alternativeNames.alternativesPreferred[geonameid] ?? [:]
            g.postcodes = postcodes
            geonames[geonameid] = g
        }
        
        precondition(geonames.count == count)
        
        var languagesMap = [String: UInt16]()
        languagesMap.reserveCapacity(alternativeNames.languages.count)
        for (id, language) in alternativeNames.languages.enumerated() {
            languagesMap[language] = UInt16(id)
        }
        
        self.geonames = geonames
        self.timezones = timeszones.strings
        //self.countryIso2 = countryIso2.strings
        //self.featureCodes = featureCodes.strings
        self.languages = alternativeNames.languages
        //self.countries = countries
        //self.languagesMap = languagesMap
        
        logger.info("Geonames: Finished loading in \(Date().timeIntervalSince(start)) seconds, \(geonames.count) entries")
    }
    
    func includeInSearchIndex(featureCode: String) -> Bool {
        //let featureCode = featureCodes[Int(geoname.featureCodeId)]
        switch featureCode {
        case "PCL": fallthrough
        case "ADM1": fallthrough
        case "ADM2": fallthrough
        case "ADM3": fallthrough
        case "ADM4": fallthrough
        case "ADM5": fallthrough
        case "LTER": fallthrough
        case "PRSH": fallthrough
        case "TERR": fallthrough
        case "ZN": fallthrough
        case "ZNB": return false
        default: return true
        }
    }
    
    /// Whether or not to include feature codes from loading
    static func includeGeoname(featureCode: String) -> Bool {
        switch featureCode {
        case "ADM1": fallthrough
        case "ADM2": fallthrough
        case "ADM3": fallthrough
        case "ADM4": fallthrough
        case "ADM5": fallthrough
        case "PCLI": fallthrough
        case "PCLD": fallthrough
        case "PCLIX": fallthrough
        case "PCLS": fallthrough
        case "PCLF": fallthrough
        case "PCL": fallthrough
        case "PPL": fallthrough
        case "PPLL": fallthrough
        case "PPLC": fallthrough
        case "PPLA": fallthrough
        case "PPLA2": fallthrough
        case "PPLA3": fallthrough
        case "PPLA4": fallthrough
        case "PPLX": fallthrough
        case "PPLS": fallthrough
        case "PPLCH": fallthrough
        case "PPLG": fallthrough
        case "AMUS": fallthrough
        case "AIRP": fallthrough
        case "MT": fallthrough
        case "MTS": fallthrough
        case "PK": fallthrough
        case "PKS": fallthrough
        case "PAN": fallthrough
        case "PANS": fallthrough
        case "PASS": fallthrough
        case "VALL": fallthrough
        case "VALX": fallthrough
        case "VALG": fallthrough
        case "VALS": fallthrough
        case "FLLS": fallthrough
        case "DAM": fallthrough
        case "PRK": fallthrough
        case "GLCR": fallthrough
        case "CONT": fallthrough
        case "UPLD": fallthrough
        case "ISL": fallthrough
        case "ISLET": fallthrough
        case "ISLF": fallthrough
        case "ISLM": fallthrough
        case "ISLS": fallthrough
        case "ISLT": fallthrough
        case "CAPE": fallthrough
        case "AIRF": fallthrough
        case "AIRB": fallthrough
        case "AIRH": return true
        default: return false
        }
    }
    
    // Rank higher popoluation counts higher
    static func populationToRank(_ population: UInt32) -> Float {
        if population <= 0 {
            return 0
        }
        let a: Float = 1.0
        let t: Float = -1.0/50000
        let b: Float = 25.0
        let e: Float = 2.7182818284590452353602874
        let rank = a / (1 + b * powf(e, t * Float(population)))
        return rank
    }
}

/**
 Helper to quickly index large amounts of duplicate strings
 */
struct DeduplicatedStrings<T: SignedInteger> {
    var strings = [String]()
    var positions = [Int: T]()
    
    mutating func findOrAppend(_ element: UnsafeRawBufferPointer) -> T {
        if let index = positions[element.hashValue] {
            return index
        }
        strings.append(element.string)
        positions[element.hashValue] = T(strings.endIndex - 1)
        return T(strings.endIndex - 1)
    }
}
