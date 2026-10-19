import ArgumentParser
import Configuration
import Foundation
import Vapor

public struct GeocodingCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "geocoding-api",
        abstract: "Serve and manage the geocoding database.",
        subcommands: [ServeCommand.self, BuildDatabaseCommand.self, VerifyDatabaseCommand.self],
        defaultSubcommand: ServeCommand.self
    )

    public init() {}
}

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve", abstract: "Start the HTTP server.")

    @Option(name: [.customLong("env"), .customShort("e")], help: "Environment (defaults to VAPOR_ENV or development).")
    var environment: String?

    @Option(help: "Hostname to listen on.")
    var hostname: String?

    @Option(help: "Port to listen on.")
    var port: Int?

    @Option(name: [.long, .customShort("b")], help: "Bind address as hostname:port.")
    var bind: String?

    @Option(help: "Unix domain socket path.")
    var unixSocket: String?

    func validate() throws {
        if let port, !(1...65535).contains(port) {
            throw ValidationError("Port must be between 1 and 65535.")
        }
        if (bind != nil && (hostname != nil || port != nil || unixSocket != nil))
            || (unixSocket != nil && (hostname != nil || port != nil))
        {
            throw ValidationError("Use --bind, --unix-socket, or --hostname/--port together.")
        }
        if let bind {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty,
                let port = Int(parts[1]), (1...65535).contains(port)
            else { throw ValidationError("Bind address must be hostname:port with a valid port.") }
        }
    }

    func makeApplication() throws -> Application {
        let environment = Environment(
            configString: environment ?? ProcessInfo.processInfo.environment["VAPOR_ENV"] ?? "development"
        )!
        // ArgumentParser owns CLI parsing. An empty provider also prevents the shell's
        // HOSTNAME variable from overriding an explicit bind address at startup.
        let app = try Application(environment, configReader: .init(provider: InMemoryProvider(values: [:])))
        if let bind {
            let parts = bind.split(separator: ":")
            app.serverConfiguration.address = .hostname(String(parts[0]), port: Int(parts[1])!)
        } else if let unixSocket {
            app.serverConfiguration.address = .unixDomainSocket(path: unixSocket)
        } else {
            if let hostname { app.serverConfiguration.hostname = hostname }
            if let port { app.serverConfiguration.port = port }
        }
        return app
    }

    func run() async throws {
        let app = try makeApplication()
        try await configure(app)
        try await app.start()
    }
}
