import ArgumentParser
import Logging
import Vapor

struct BuildDatabaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build-database",
        abstract: "Build the memory-mapped geocoding database from GeoNames source files."
    )

    @Flag(help: "Replace an existing database-v1.bin after a successful build.")
    var force = false

    func run() throws {
        try GeocodingDatabaseBuilder(
            logger: Logger.current,
            options: DatabaseBuildOptions(force: force)
        ).build()
        print("Built \(GeocodingDatabaseBuilder.databaseFile.path)")
    }
}
