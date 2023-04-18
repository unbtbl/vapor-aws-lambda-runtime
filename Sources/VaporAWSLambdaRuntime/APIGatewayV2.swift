import AWSLambdaEvents
import AWSLambdaRuntimeCore
import ExtrasBase64
import NIO
import NIOHTTP1
import Vapor

// MARK: - Request -

extension Vapor.Request {
    private static let bufferAllocator = ByteBufferAllocator()

    convenience init(req: APIGatewayV2Request, in ctx: LambdaContext, for application: Application) throws {
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

        if let cookies = req.cookies, cookies.count > 0 {
            nioHeaders.add(name: "Cookie", value: cookies.joined(separator: "; "))
        }

        var url: String = req.rawPath
        if req.rawQueryString.count > 0 {
            url += "?\(req.rawQueryString)"
        }

        self.init(
            application: application,
            method: NIOHTTP1.HTTPMethod(rawValue: req.context.http.method.rawValue),
            url: Vapor.URI(path: url),
            version: HTTPVersion(major: 1, minor: 1),
            headers: nioHeaders,
            collectedBody: buffer,
            remoteAddress: nil,
            logger: ctx.logger,
            on: ctx.eventLoop
        )

        storage[APIGatewayV2RequestStorageKey.self] = req
    }
}

fileprivate struct APIGatewayV2RequestStorageKey: Vapor.StorageKey {
    typealias Value = APIGatewayV2Request
}

extension Request {
    public var apiGatewayV2Request: APIGatewayV2Request? {
        storage[APIGatewayV2RequestStorageKey.self]
    }
}

// MARK: - Response -

extension APIGatewayV2Response {
    static func from(response: Vapor.Response, in context: LambdaContext) -> EventLoopFuture<APIGatewayV2Response> {
        // Create the headers
        var headers = [String: String]()
        response.headers.forEach { name, value in
            if let current = headers[name] {
                headers[name] = "\(current),\(value)"
            } else {
                headers[name] = value
            }
        }

        // Can we access the body right away?
        if let string = response.body.string {
            return context.eventLoop.makeSucceededFuture(.init(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                headers: headers,
                body: string,
                isBase64Encoded: false
            ))
        } else if let bytes = response.body.data {
            return context.eventLoop.makeSucceededFuture(.init(
                statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                headers: headers,
                body: String(base64Encoding: bytes),
                isBase64Encoded: true
            ))
        } else {
            // See if it is a stream and try to gather the data
            return response.body.collect(on: context.eventLoop).map { buffer -> APIGatewayV2Response in
                // Was there any content
                guard
                    var buffer = buffer,
                    let bytes = buffer.readBytes(length: buffer.readableBytes)
                else {
                    return APIGatewayV2Response(
                        statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                        headers: headers
                    )
                }

                // Done
                return APIGatewayV2Response(
                    statusCode: AWSLambdaEvents.HTTPResponseStatus(code: response.status.code),
                    headers: headers,
                    body: String(base64Encoding: bytes),
                    isBase64Encoded: true
                )
            }
        }
    }
}
