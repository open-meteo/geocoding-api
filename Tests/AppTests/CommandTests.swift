import ArgumentParser
import Testing

@testable import App

struct CommandTests {
    @Test
    func deploymentArgumentsRemainSupported() throws {
        let service = try #require(
            GeocodingCommand.parseAsRoot([
                "serve", "-b", "127.0.0.1:8082", "--env", "production",
            ]) as? ServeCommand
        )
        #expect(service.bind == "127.0.0.1:8082")
        #expect(service.environment == "production")
        let serviceApp = try service.makeApplication()
        #expect(serviceApp.environment == .production)
        #expect(serviceApp.serverConfiguration.hostname == "127.0.0.1")
        #expect(serviceApp.serverConfiguration.port == 8082)
        #expect(serviceApp.configReader.string(forKey: "hostname") == nil)

        let docker = try #require(
            GeocodingCommand.parseAsRoot([
                "serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080",
            ]) as? ServeCommand
        )
        #expect(docker.hostname == "0.0.0.0")
        #expect(docker.port == 8080)
        let dockerApp = try docker.makeApplication()
        #expect(dockerApp.serverConfiguration.hostname == "0.0.0.0")
        #expect(dockerApp.serverConfiguration.port == 8080)
        #expect(try GeocodingCommand.parseAsRoot([]) is ServeCommand)
    }

    @Test
    func databaseCommandsRemainIndependentOfServer() throws {
        let build = try #require(
            GeocodingCommand.parseAsRoot([
                "build-database", "--force",
            ]) as? BuildDatabaseCommand
        )
        #expect(build.force)
        let verify = try #require(
            GeocodingCommand.parseAsRoot([
                "verify-database", "--database", "/tmp/example.bin",
            ]) as? VerifyDatabaseCommand
        )
        #expect(verify.database == "/tmp/example.bin")
    }

    @Test
    func invalidAddressOptionsAreRejected() {
        for arguments in [
            ["serve", "--port", "0"],
            ["serve", "--bind", "invalid"],
            ["serve", "--bind", "localhost:8080", "--port", "8081"],
        ] {
            #expect(throws: (any Error).self) { try GeocodingCommand.parseAsRoot(arguments) }
        }
    }
}
