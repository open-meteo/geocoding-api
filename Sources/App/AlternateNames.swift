import Foundation
import Vapor


struct AlternateNames {
    let alternativesPreferred: [Int32: [Int32: String]]
    let postcodes: [Int32: [String]]
    let languages: [String]
    
    /**
     The table 'alternate names' :
     -----------------------------
     0. alternateNameId   : the id of this alternate name, int
     1. geonameid         : geonameId referring to id in table 'geoname', int
     2. isolanguage       : iso 639 language code 2- or 3-characters; 4-characters 'post' for postal codes and 'iata','icao' and faac for airport codes, fr_1793 for French Revolution names,  abbr for abbreviation, link to a website (mostly to wikipedia), wkdt for the wikidataid, varchar(7)
     3. alternate name    : alternate name or name variant, varchar(400)
     4. isPreferredName   : '1', if this alternate name is an official/preferred name
     5. isShortName       : '1', if this is a short name like 'California' for 'State of California'
     6. isColloquial      : '1', if this alternate name is a colloquial or slang term. Example: 'Big Apple' for 'New York'.
     7. isHistoric        : '1', if this alternate name is historic and was used in the past. Example 'Bombay' for 'Mumbai'.
     8. from          : from period when the name was used
     9. to          : to period when the name was used
     */
    public init(data: Data, logger: Logger) {
        let start = Date()
        logger.info("Alternative names: Start loading")
        let tab = Character("\t").asciiValue!
                
        var languages = DeduplicatedStrings<Int32>()
        var alternateNames = [Int32: [AlternateName]]()
        var postcodes = [Int32: [String]]()
                
        data.forEachLine { line in
            if line.isEmpty {
                return
            }
            var offset = 0
                        
            let _ = line.seekUntil(value: tab, offset: &offset) // alternatenameid
            let geonameid = line.seekUntil(value: tab, offset: &offset).asciiToInt32
            let isolanguage = line.seekUntil(value: tab, offset: &offset)
            let alternateName = line.seekUntil(value: tab, offset: &offset).string
            let isPreferredName = line.seekUntil(value: tab, offset: &offset).asciiToInt8
            let isShortName = line.seekUntil(value: tab, offset: &offset).asciiToInt8
            let isColloquial = line.seekUntil(value: tab, offset: &offset).asciiToInt8
            //let isHistoric = line[line.seekUntil(value: tab, offset: &offset)].asciiToInt8
            
            let isolanguageString = isolanguage.string
            
            if isolanguageString == "link" || isolanguageString == "wkdt" || isolanguageString == "fr_1793" {
                return
            }
            
            if  isColloquial == 1 { //isHistoric == 1 ||
                return
            }
            
            if isolanguageString == "post" {
                if postcodes[geonameid] == nil {
                    postcodes[geonameid] = [alternateName]
                } else {
                    postcodes[geonameid]?.append(alternateName)
                }
                return
            }
            
            let alternateNameStruct = AlternateName(
                //geonameid: geonameid,
                languageId: languages.findOrAppend(isolanguage),
                alternateName: alternateName,
                isPreferredeName: isPreferredName != 0,
                isShortName: isShortName != 0
            )
            
            if alternateNames[geonameid] != nil {
                alternateNames[geonameid]?.append(alternateNameStruct)
            } else {
                alternateNames[geonameid] = [alternateNameStruct]
            }
        }
        
        var alternativesPreferred = [Int32: [Int32: String]]()
        alternativesPreferred.reserveCapacity(alternateNames.count)
        for (id, names) in alternateNames {
            /// For each langauge, find tthe most suitable alternativeName. Prefer short ones
            let languageIds = names.unique(of: {$0.languageId})
            var res = [Int32: String]()
            res.reserveCapacity(languageIds.count)
            for languageId in languageIds {
                let perLanguage = names.filter({$0.languageId == languageId })
                res[languageId] = perLanguage.getPreferred()
            }
            alternativesPreferred[id] = res
        }
        
        self.languages = languages.strings
        self.alternativesPreferred = alternativesPreferred
        self.postcodes = postcodes
        
        logger.info("Alternative names: Finished loading in \(Date().timeIntervalSince(start)) seconds")
    }
}

fileprivate struct AlternateName {
    //let geonameid: Int32
    let languageId: Int32
    let alternateName: String
    let isPreferredeName: Bool
    let isShortName: Bool
}

fileprivate extension Array where Element == AlternateName {
    func getPreferred() -> String {
        var short: String? = nil
        var preferred: String? = nil
        var other: String? = nil
        for alternate in self {
            if alternate.isPreferredeName && alternate.isShortName {
                return alternate.alternateName
            }
            if alternate.isShortName {
                short = alternate.alternateName
                continue
            }
            if alternate.isPreferredeName {
                preferred = alternate.alternateName
                continue
            }
            other = alternate.alternateName
        }
        return short ?? preferred ?? other ?? ""
    }
}
