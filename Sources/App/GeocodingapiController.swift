import Foundation
import Vapor

/**
 API Endpoints:
 /v1/search?name=Berlin (&country=DE &count=30 &lang=de)  later maybe &page=1
 Queries with 0 or 1 character, return empty results
 2 character only exact match
 3 characters and more prefix search

 // langauge ICAO and IATA also works!
 /v1/get?id=12345 &lang=de
 /v1/proximity?latitude=12&longitude=12 (&radius=30 &count=30 &page=1)
 /v1/geoip
 */

struct GeocodingapiController: RouteCollection {
    let database: GeocodingDatabase
    let administrativeAreaResolver: AdministrativeAreaResolver

    public init(_ app: Application) throws {
        try self.init(database: GeocodingDatabase.loadOrCreate(logger: app.logger))
    }

    init(database: GeocodingDatabase) throws {
        self.database = database
        self.administrativeAreaResolver = try AdministrativeAreaResolver(
            database: database
        )
        _ = database.searchIndex
    }

    static func parseSearchName(_ value: String) -> (name: String, areaName: String?) {
        guard let comma = value.firstIndex(of: ",") else {
            return (value.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }

        let name = String(value[..<comma]).trimmingCharacters(in: .whitespacesAndNewlines)
        let areaStart = value.index(after: comma)
        let areaEnd = value[areaStart...].firstIndex(of: ",") ?? value.endIndex
        let areaName =
            String(value[areaStart..<areaEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name, areaName.isEmpty ? nil : areaName)
    }

    func boot(routes: RoutesBuilder) throws {
        let cors = CORSMiddleware(
            configuration: .init(
                allowedOrigin: .all,
                allowedMethods: [.GET, /*.POST, .PUT,*/ .OPTIONS /*.DELETE, .PATCH*/],
                allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
            )
        )
        let corsGroup = routes.grouped(cors, ErrorMiddleware.default(environment: try .detect()))
        let categoriesRoute = corsGroup.grouped("v1")
        categoriesRoute.get("search", use: self.search)
        //categoriesRoute.get("proximity", use: self.proxmity)
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
        let languageId = database.languageIDs[language] ?? database.languageIDs["en"] ?? 0
        let count = try params.getCount()

        let parsedName = Self.parseSearchName(params.name)
        let administrativeAreaResolution = parsedName.areaName.map {
            administrativeAreaResolver.resolve(
                $0,
                languageID: languageId,
                countryCode: params.countryCode
            )
        }

        let results =
            parsedName.name.count < 2
            ? []
            : database.searchIndex.search(
                parsedName.name,
                languageID: languageId,
                count: count,
                countryCode: params.countryCode,
                administrativeArea: administrativeAreaResolution
            )
        let mapped: [GeocodingApi.Geoname] = try results.map({
            guard let geoname = try database.response(id: $0.0, languageID: languageId)
            else {
                fatalError("Geoname in search index was not in database.")
            }
            return geoname
        })
        var out = GeocodingApi.SearchResults()
        out.results = mapped
        out.generationtimeMs = Float(Date().timeIntervalSince(start) * 1000)
        return request.eventLoop.makeSucceededFuture(try out.encode(format: params.format))
    }

    func get(_ request: Request) throws -> EventLoopFuture<Response> {
        struct GetQuery: Content {
            let id: Int32
            let language: String?
            let format: ProtobufSerializationFormat?
        }
        let params = try request.query.decode(GetQuery.self)
        let language = params.language ?? "en"
        let languageId = database.languageIDs[language] ?? database.languageIDs["en"] ?? 0

        guard let out = try database.response(id: params.id, languageID: languageId)
        else {
            throw GeocodingApiError.locationNotFound(id: params.id)
        }
        return request.eventLoop.makeSucceededFuture(try out.encode(format: params.format))
    }
}

enum GeocodingApiError: Error {
    case locationNotFound(id: Int32)
    case invalidCount
}

extension GeocodingApiError: AbortError {
    var status: HTTPResponseStatus {
        return .badRequest
    }

    var reason: String {
        switch self {
        case .locationNotFound(id: _):
            return "Location ID not found."
        case .invalidCount:
            return "Parameter count must be between 1 and 100."
        }
    }
}
