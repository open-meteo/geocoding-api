import ArgumentParser
import Foundation

struct VerifyDatabaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify-database",
        abstract: "Fully verify hashes, references, names, and ranking bounds in an immutable database."
    )

    @Option(help: "Database path (default: data/database-v1.bin)")
    var database: String?

    func run() throws {
        let url = database.map { URL(fileURLWithPath: $0) } ?? GeocodingDatabase.databaseFile
        let database = try GeocodingDatabase(url: url, verification: .full)
        print("Verified \(database.recordCount) locations in \(url.path)")
    }
}
