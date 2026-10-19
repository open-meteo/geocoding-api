import Foundation
import Logging
import Vapor

public func configure(_ app: Application) async throws {
    TimeZone.ReferenceType.default = TimeZone(abbreviation: "GMT")!
    try await configure(app, database: GeocodingDatabase.open(logger: Logger.current))
}

func configure(_ app: Application, database: GeocodingDatabase) async throws {
    // CORS must wrap error handling so error responses also include its headers.
    app.middleware.use(
        CORSMiddleware(
            configuration: .init(
                allowedOrigin: .all,
                allowedMethods: [.get, .options],
                allowedHeaders: [.accept, .authorization, .contentType, .origin, .xRequestedWith]
            )
        ),
        at: .beginning
    )
    try await app.routes.register(collection: GeocodingapiController(database: database))
}
