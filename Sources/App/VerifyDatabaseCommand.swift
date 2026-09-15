import Foundation
import Vapor

struct VerifyDatabaseCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "database", help: "Database path (default: data/database-v3.bin)")
        var database: String?
    }
    let help = "Fully verify hashes, references, names, and ranking bounds in an immutable database."

    func run(using context: CommandContext, signature: Signature) async throws {
        let url = signature.database.map { URL(fileURLWithPath: $0) } ?? GeocodingDatabase.databaseFile
        let database = try GeocodingDatabase(url: url, verification: .full)
        context.console.success("Verified \(database.recordCount) locations in \(url.path)")
    }
}
