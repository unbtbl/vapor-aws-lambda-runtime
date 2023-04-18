import AWSLambdaEvents
import AWSLambdaRuntime
import ExtrasBase64
import NIO
import NIOHTTP1
import Vapor

// MARK: - Request -

extension Vapor.Request {
    private static let bufferAllocator = ByteBufferAllocator()

    convenience init(req: APIGatewayRequest, in ctx: LambdaContext, for application: Application) throws {
        var buffer: NIO.ByteBuffer?
        switch (req.body, req.isBase64Encoded) {
        case (let .some(string), true):
            let bytes = try string.base64decoded()
            buffer = Vapor.Request.bufferAllocator.buffer(capacity: bytes.count)
            buffer!.writeBytes(bytes)

        case (let .some(string), false):
            buffer = Vapor.Request.bufferAllocator.buffer(capacity: string.utf8.count)
            buffer!.writeString(string)

        case (.none, _):
            break
        }

        var nioHeaders = NIOHTTP1.HTTPHeaders()
        req.headers.forEach { key, value in
            nioHeaders.add(name: key, value: value)
        }

        self.init(
            application: application,
            method: NIOHTTP1.HTTPMethod(rawValue: req.httpMethod.rawValue),
            url: Vapor.URI(path: req.path),
            version: HTTPVersion(major: 1, minor: 1),
            headers: nioHeaders,
            collectedBody: buffer,
            remoteAddress: nil,
            logger: ctx.logger,
            on: ctx.eventLoop
        )

        storage[APIGatewayRequestStorageKey.self] = req
    }
}

fileprivate struct APIGatewayRequestStorageKey: StorageKey {
    typealias Value = APIGatewayRequest
}

extension Request {
    public var apiGatewayRequest: APIGatewayRequest? {
        storage[APIGatewayRequestStorageKey.self]
    }
}

// MARK: - Response -

extension APIGatewayResponse {
    init(response: Vapor.Response) {
        var headers = [String: [String]]()
        response.headers.forEach { name, value in
            var values = headers[name] ?? [String]()
            values.append(value)
            headers[name] = values
        }

        if let string = response.body.string {
            self = APIGatewayResponse(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                multiValueHeaders: headers,
                body: string,
                isBase64Encoded: false
            )
        } else if var buffer = response.body.buffer {
            let bytes = buffer.readBytes(length: buffer.readableBytes)!
            self = APIGatewayResponse(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                multiValueHeaders: headers,
                body: String(base64Encoding: bytes),
                isBase64Encoded: true
            )
        } else {
            self = APIGatewayResponse(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                multiValueHeaders: headers
            )
        }
    }
}
