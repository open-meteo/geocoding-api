import ConsoleKit
import Vapor

struct BuildDatabaseCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(
            name: "force",
            help: "Replace an existing database-v2.bin after a successful build."
        )
        var force: Bool

        @Option(
            name: "memory-limit-mb",
            help: "Approximate total builder memory budget in MiB (default: 1024)."
        )
        var memoryLimitMB: String?
    }

    let help = "Build the memory-mapped geocoding database from GeoNames source files."

    func run(
        using context: ConsoleKitCommands.CommandContext,
        signature: Signature
    ) async throws {
        let memoryLimit = try Self.positiveInteger(
            signature.memoryLimitMB,
            name: "memory-limit-mb",
            default: 1024
        )
        let (memoryLimitBytes, memoryLimitOverflow) = memoryLimit.multipliedReportingOverflow(
            by: 1_048_576
        )
        guard !memoryLimitOverflow else {
            throw Abort(
                .badRequest,
                reason: "--memory-limit-mb is too large for this platform."
            )
        }
        if FileManager.default.fileExists(
            atPath: GeocodingDatabaseBuilder.databaseFile.path
        ), !signature.force {
            throw Abort(
                .conflict,
                reason:
                    "database-v2.bin already exists; pass --force to replace it atomically."
            )
        }
        try await GeocodingDatabaseBuilder(
            logger: context.application.logger,
            options: DatabaseBuildOptions(
                memoryLimitBytes: memoryLimitBytes,
                force: signature.force
            )
        ).build()
        context.console.success("Built \(GeocodingDatabaseBuilder.databaseFile.path)")
    }

    private static func positiveInteger(
        _ value: String?,
        name: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let value else {
            return defaultValue
        }
        guard let parsed = Int(value), parsed > 0 else {
            throw Abort(.badRequest, reason: "--\(name) must be a positive integer.")
        }
        return parsed
    }
}
