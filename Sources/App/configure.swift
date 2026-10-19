import Foundation
import Vapor

public func configure(_ app: Application) async throws {
    TimeZone.ReferenceType.default = TimeZone(abbreviation: "GMT")!
    try await app.routes.register(collection: try GeocodingapiController(app))
}
