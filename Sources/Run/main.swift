import App
import Vapor

#if Xcode
let projectHome = String(#file[...#file.range(of: "/Sources/")!.lowerBound])
FileManager.default.changeCurrentDirectoryPath(projectHome)
#endif

var env = try Environment.detect()
try LoggingSystem.bootstrap(from: &env)
let app = try await Application.make(env)
try configure(app)
try await app.execute()
try await app.asyncShutdown()
