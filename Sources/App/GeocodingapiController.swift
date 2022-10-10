import Foundation
import Vapor

/**
 API Endpoints:
 /v1/search?name=Berlin (&country=DE &count=30 &lang=de)  later maybe &page=1
 Queries with 0 or 1 character, return empty results
 2 character only exact match
 3 character and more fuzzy search
 
 // langauge ICAO and IATA also works!
 /v1/get?id=12345 &lang=de
 /v1/proximity?latitude=12&longitude=12 (&radius=30 &count=30 &page=1)
 /v1/geoip
 */

struct GeocodingapiController: RouteCollection {
    let database: GeocodingDatabase
    
    public init(_ app: Application) throws {
        database = try GeocodingDatabase.loadOrCreate(logger: app.logger)
    }
    
    func boot(routes: RoutesBuilder) throws {
        let cors = CORSMiddleware(configuration: .init(
            allowedOrigin: .all,
            allowedMethods: [.GET, /*.POST, .PUT,*/ .OPTIONS, /*.DELETE, .PATCH*/],
            allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
        ))
        let corsGroup = routes.grouped(cors, ErrorMiddleware.default(environment: try .detect()))
        let categoriesRoute = corsGroup.grouped("v1")
        categoriesRoute.get("search", use: self.search)
        categoriesRoute.get("proximity", use: self.proxmity)
        categoriesRoute.get("get", use: self.get)
    }
    
    func search(_ request: Request) throws -> EventLoopFuture<Response> {
        struct SearchQuery: Content {
            let name: String
            let language: String?
            let countryCode: String?
            let format: ProtobufSerializationFormat?
            let count: Int?
            
            func getCount() throws -> Int {
                let count = self.count ?? 10
                guard count > 0 && count <= 100 else {
                    throw GeocodingApiError.invalidCount
                }
                return count
            }
        }
        let start = Date()
        let params = try request.query.decode(SearchQuery.self)
        let language = params.language ?? "en"
        let languageId = database.geonames.languages.firstIndex(of: language) ?? database.geonames.languages.firstIndex(of: "en")!
        let count = try params.getCount()

        var name = params.name
        var areaIds: [Int32]?
        if name.contains(",") { // Split string by comma, so we can filter the results later by second part
            let parts = name.components(separatedBy: ",")
            name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let areaName = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if areaName.count > 1 {
                areaIds = database.search(areaName, languageId: Int32(languageId), maxCount: 10).compactMap({
                    guard ["ADM1","ADM2","ADM3","ADM4","PCLI"].contains(database.geonames.geonames[$0.0]?.featureCode) else {
                        return nil
                    }
                    return $0.0
                })
            }
        }

        var results = params.name.count < 2 ? [] : database.search(name, languageId: Int32(languageId), maxCount: count)
        /// TODO country filter need to be inside database match, because `count` would be wrong otherwise
        if let countryCode = params.countryCode {
            /*guard let countryId = searchTree.geonames.countryIso2.firstIndex(of: countryCode) else {
                throw GeocodingApiError.invalidContryCode
            }*/
            results = results.filter({
                guard let c = database.geonames.geonames[$0.0]?.countryIso2 else {
                    return false
                }
                return c == countryCode
            })
        }
        if let areas = areaIds {
            results = results.filter({ // Filter the results by second part of the original string
                return areas.contains(database.geonames.geonames[$0.0]?.admin1ID ?? -1)
                    || areas.contains(database.geonames.geonames[$0.0]?.admin2ID ?? -1)
                    || areas.contains(database.geonames.geonames[$0.0]?.admin3ID ?? -1)
                    || areas.contains(database.geonames.geonames[$0.0]?.admin4ID ?? -1)
                    || areas.contains(database.geonames.geonames[$0.0]?.countryID ?? -1)
            })
        }
        let mapped: [GeocodingApi.Geoname] = results.map({
            guard let geoname = database.geonames.getResponse(id: $0.0, languageId: Int32(languageId), searchRank: $0.1) else {
                fatalError("Geoname in search index was not in database.")
            }
            return geoname
        })
        var out = GeocodingApi.SearchResults()
        out.results = mapped
        out.generationtimeMs = Float(Date().timeIntervalSince(start)*1000)
        return request.eventLoop.makeSucceededFuture(try out.encode(format: params.format))
    }
    
    
    func proxmity(_ request: Request) throws -> EventLoopFuture<Response> {
        struct SearchQuery: Content {
            let latitude: Float
            let longitude: Float
            let language: String?
            let countryCode: String?
            let format: ProtobufSerializationFormat?
            let count: Int?
            
            func getCount() throws -> Int {
                let count = self.count ?? 10
                guard count > 0 && count <= 100 else {
                    throw GeocodingApiError.invalidCount
                }
                return count
            }
        }
        let start = Date()
        let params = try request.query.decode(SearchQuery.self)
        let language = params.language ?? "en"
        let languageId = database.geonames.languages.firstIndex(of: language) ?? database.geonames.languages.firstIndex(of: "en")!
        let count = try params.getCount()
        // TODO ranking by distance OR priority
        var results = database.proximity(latitude: params.latitude, longitude: params.longitude, maxCount: count, maxDistanceKilometer: 100)
        /// TODO country filter need to be inside database match, because `count` would be wrong otherwise
        if let countryCode = params.countryCode {
            /*guard let countryId = searchTree.geonames.countryIso2.firstIndex(of: countryCode) else {
                throw GeocodingApiError.invalidContryCode
            }*/
            results = results.filter({
                guard let c = database.geonames.geonames[$0.0]?.countryIso2 else {
                    return false
                }
                return c == countryCode
            })
        }
        let mapped: [GeocodingApi.Geoname] = results.map({
            guard let geoname = database.geonames.getResponse(id: $0.0, languageId: Int32(languageId), searchRank: $0.1) else {
                fatalError("Geoname in search index was not in database.")
            }
            return geoname
        })
        var out = GeocodingApi.SearchResults()
        out.results = mapped
        out.generationtimeMs = Float(Date().timeIntervalSince(start)*1000)
        return request.eventLoop.makeSucceededFuture(try out.encode(format: params.format))
    }
    
    func get(_ request: Request) throws -> EventLoopFuture<Response>{
        struct GetQuery: Content {
            let id: Int32
            let language: String?
            let format: ProtobufSerializationFormat?
        }
        let params = try request.query.decode(GetQuery.self)
        let language = params.language ?? "en"
        let languageId = database.geonames.languages.firstIndex(of: language) ?? database.geonames.languages.firstIndex(of: "en")!
        
        guard let out = database.geonames.getResponse(id: params.id, languageId: Int32(languageId), searchRank: 0) else {
            throw GeocodingApiError.locationNotFound(id: params.id)
        }
        return request.eventLoop.makeSucceededFuture(try out.encode(format: params.format))
    }
}

enum GeocodingApiError: Error {
    case locationNotFound(id: Int32)
    case invalidCount
    //case invalidContryCode
}

extension GeocodingApiError: AbortError {
    var status: HTTPResponseStatus {
        return .badRequest
    }
    
    var reason: String {
        switch self {
        case .locationNotFound(id: _):
            return "Location ID not found."
        //case .invalidContryCode:
        //    return "Invalid country code"
        case .invalidCount:
            return "Parameter count must be between 1 and 100."
        }
    }
}


extension GeocodingDatabase.Geoname {
    func getName(languageId: Int32) -> String {
        return alternativeNames.first(where: {$0.0 == languageId})?.1 ?? name
    }
}

extension GeocodingDatabase.Geonames {
    func getResponse(id: Int32, languageId: Int32, searchRank: Float) -> GeocodingApi.Geoname? {
        guard let g = geonames[id] else {
            return nil
        }
        
        var out = GeocodingApi.Geoname()
        out.id = g.id
        out.name = g.getName(languageId: languageId)
        out.latitude = g.latitude
        out.longitude = g.longitude
        out.elevation = g.elevation
        out.countryCode = g.countryIso2
        out.countryID = g.countryID
        out.country = geonames[g.countryID]?.getName(languageId: languageId) ?? ""
        out.featureCode = g.featureCode
        out.admin1ID = g.admin1ID
        out.admin2ID = g.admin2ID
        out.admin3ID = g.admin3ID
        out.admin4ID = g.admin4ID
        out.admin1 = geonames[g.admin1ID]?.getName(languageId: languageId) ?? ""
        out.admin2 = geonames[g.admin2ID]?.getName(languageId: languageId) ?? ""
        out.admin3 = geonames[g.admin3ID]?.getName(languageId: languageId) ?? ""
        out.admin4 = geonames[g.admin4ID]?.getName(languageId: languageId) ?? ""
        out.population = g.population
        out.timezone = timezones[Int(g.timezoneIndex)]
        out.postcodes = g.postcodes
        //out.ranking = g.ranking
        //out.searchRank = searchRank
        return out
    }
}
