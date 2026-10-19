import Foundation
import HTTPTypes
import Testing
import Vapor
import VaporTesting

@testable import App

struct HTTPTests {
    @Test(arguments: [false, true])
    func responsesAndErrors(overHTTP: Bool) async throws {
        let fixture = try DatabaseFixture(count: 20)
        defer { fixture.remove() }
        let database = try fixture.build()
        let id = try #require(fixture.places.first?.id)
        try await withApp { app in
            try await configure(app, database: database)
            try await app.testing(overHTTP ? .running : .inMemory) { client in
                var json = try await client.get("/v1/get?id=\(id)", headers: [.origin: "https://example.com"])
                #expect(json.status == .ok)
                #expect(json.headers[.accessControlAllowOrigin] == "*")
                #expect(json.headers.contentType == .json)
                #expect(json.headers[HTTPField.Name("X-Encoding-Time")!] != nil)
                let jsonData = try #require(await json.body.collect())
                let decodedJSON = try GeocodingApi.Geoname(jsonUTF8Data: jsonData)
                #expect(decodedJSON.id == id)

                var protobuf = try await client.get("/v1/get?id=\(id)&format=protobuf")
                #expect(protobuf.status == .ok)
                #expect(protobuf.headers.contentType == .init(type: "application", subType: "x-protobuf"))
                let protobufData = try #require(await protobuf.body.collect())
                let decodedProtobuf = try GeocodingApi.Geoname(serializedBytes: protobufData)
                #expect(decodedProtobuf == decodedJSON)

                var search = try await client.get("/v1/search?name=a")
                #expect(search.status == .ok)
                let searchData = try #require(await search.body.collect())
                let results = try GeocodingApi.SearchResults(jsonUTF8Data: searchData)
                #expect(results.results.isEmpty)

                for path in ["/v1/search?name=test&count=0", "/v1/get?id=-1", "/v1/get?id=invalid"] {
                    let error = try await client.get(URI(string: path), headers: [.origin: "https://example.com"])
                    #expect(error.status == .badRequest)
                    #expect(error.headers[.accessControlAllowOrigin] == "*")
                }
                let missing = try await client.get("/missing", headers: [.origin: "https://example.com"])
                #expect(missing.status == .notFound)
                #expect(missing.headers[.accessControlAllowOrigin] == "*")

                for path in ["/v1/search", "/v1/get", "/missing"] {
                    let preflight = try await client.send(
                        .init(
                            method: .options,
                            url: URI(string: path),
                            headers: [.origin: "https://example.com", .accessControlRequestMethod: "GET"]
                        )
                    )
                    #expect(preflight.status == .ok)
                    #expect(preflight.headers[.accessControlAllowOrigin] == "*")
                    #expect(preflight.headers[.accessControlAllowMethods] == "GET, OPTIONS")
                }
            }
        }
    }
}
