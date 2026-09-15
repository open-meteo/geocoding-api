import Vapor

public func configure(_ app: Application) async throws {
    TimeZone.ReferenceType.default = TimeZone(abbreviation: "GMT")!

    app.http.server.configuration.responseCompression = .enabled
    // https://github.com/vapor/vapor/pull/2677
    app.http.server.configuration.supportPipelining = false

    #if Xcode
    app.logger.logLevel = .debug
    app.http.server.configuration.port = 8912
    #endif

    app.asyncCommands.use(BuildDatabaseCommand(), as: "build-database")
    app.asyncCommands.use(VerifyDatabaseCommand(), as: "verify-database")
    if let command = app.environment.commandInput.arguments.first,
        ["build-database", "verify-database"].contains(command)
    {
        return
    }

    try await routes(app)
}

func routes(_ app: Application) async throws {
    try app.routes.register(collection: try await GeocodingapiController(app))
}
