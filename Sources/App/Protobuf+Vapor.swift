import Foundation
import Vapor
import SwiftProtobuf


enum ProtobufSerializationFormat: String, Codable {
    case json
    case protobuf
}

extension Message {
    /// Encode a protobuf message to a vapor response given a format
    func encode(format: ProtobufSerializationFormat?) throws -> Response {
        let start = Date()
        let response = Response()
        switch format ?? .json {
        case .json:
            var o = JSONEncodingOptions()
            o.preserveProtoFieldNames = true
            response.body = Response.Body(data: try self.jsonUTF8Data(options: o))
            response.headers.contentType = .json
        case .protobuf:
            response.body = Response.Body(data: try self.serializedData())
            response.headers.contentType = .init(type: "application", subType: "x-protobuf")
        }
        response.headers.add(name: "X-Encoding-Time", value: "\(Date().timeIntervalSince(start) * 100) ms")
        return response
    }
}
