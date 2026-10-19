import App
import ArgumentParser
import Foundation
import Logging

func run() async {
    LoggingSystem.bootstrap { label in
        var handler = StreamLogHandler.standardOutput(label: label)
        handler.logLevel =
            ProcessInfo.processInfo.environment["LOG_LEVEL"].flatMap(Logger.Level.init(rawValue:)) ?? .info
        return handler
    }
    await GeocodingCommand.main()
}

await run()
