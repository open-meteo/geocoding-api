import ConsoleKit
import Vapor

struct BuildDatabaseCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(
            name: "force",
            help: "Replace an existing database-v1.bin after a successful build."
        )
        var force: Bool
    }

    let help = "Build the memory-mapped geocoding database from GeoNames source files."

    func run(
        using context: ConsoleKitCommands.CommandContext,
        signature: Signature
    ) async throws {
        try GeocodingDatabaseBuilder(
            logger: context.application.logger,
            options: DatabaseBuildOptions(force: signature.force)
        ).build()
        context.console.success("Built \(GeocodingDatabaseBuilder.databaseFile.path)")
    }
}
