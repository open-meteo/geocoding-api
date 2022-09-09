import Foundation
import Vapor


struct PostalCodes {
    /**
     country code      : iso country code, 2 characters
     postal code       : varchar(20)
     place name        : varchar(180)
     admin name1       : 1. order subdivision (state) varchar(100)
     admin code1       : 1. order subdivision (state) varchar(20)
     admin name2       : 2. order subdivision (county/province) varchar(100)
     admin code2       : 2. order subdivision (county/province) varchar(20)
     admin name3       : 3. order subdivision (community) varchar(100)
     admin code3       : 3. order subdivision (community) varchar(20)
     latitude          : estimated latitude (wgs84)
     longitude         : estimated longitude (wgs84)
     accuracy          : accuracy of lat/lng from 1=estimated, 4=geonameid, 6=centroid of addresses or shape
     */
    public init(data: Data, logger: Logger) {
        let start = Date()
        logger.info("Postal codes: Start loading")
        //let tab = Character("\t").asciiValue!
        
        data.forEachLine { line in
            if line.isEmpty {
                return
            }
            // TODO need implemtation
            /*var offset = 0
                        
            let countryCode = line.seekUntil(value: tab, offset: &offset)
            let postalCode = line.seekUntil(value: tab, offset: &offset).string
            let placeName = line.seekUntil(value: tab, offset: &offset)
            let _ = line.seekUntil(value: tab, offset: &offset) // adminName1
            let _ = line.seekUntil(value: tab, offset: &offset) // adminCode1
            let _ = line.seekUntil(value: tab, offset: &offset) // adminName2
            let _ = line.seekUntil(value: tab, offset: &offset) // adminCode2
            let _ = line.seekUntil(value: tab, offset: &offset) // adminName3
            let _ = line.seekUntil(value: tab, offset: &offset) // adminCode3
            let latitude = line.seekUntil(value: tab, offset: &offset).float
            let longitude = line.seekUntil(value: tab, offset: &offset).float
            let accuracy = line.seekUntil(value: tab, offset: &offset)*/
        }

        logger.info("Postal codes: Finished loading in \(Date().timeIntervalSince(start)) seconds")
    }
}
