import App
import Vapor

#if os(Linux)
import Glibc
#else
import Darwin
#endif

#if Xcode
let projectHome = String(#file[...#file.range(of: "/Sources/")!.lowerBound])
FileManager.default.changeCurrentDirectoryPath(projectHome)
#endif

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)
do {
    try await configure(app)
    try await app.execute()
    try await app.asyncShutdown()
} catch {
    app.logger.report(error: error)
    try? await app.asyncShutdown()
    exit(EXIT_FAILURE)
}
