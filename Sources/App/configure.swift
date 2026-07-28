import Vapor

public func configure(_ app: Application) throws {
    TimeZone.ReferenceType.default = TimeZone(abbreviation: "GMT")!

    app.http.server.configuration.responseCompression = .enabled
    // https://github.com/vapor/vapor/pull/2677
    app.http.server.configuration.supportPipelining = false

    #if Xcode
    app.logger.logLevel = .debug
    app.http.server.configuration.port = 8912
    #endif

    app.asyncCommands.use(BuildDatabaseCommand(), as: "build-database")
    if app.environment.commandInput.arguments.first == "build-database" {
        return
    }

    try routes(app)
}

func routes(_ app: Application) throws {
    try app.routes.register(collection: try GeocodingapiController(app))
}
