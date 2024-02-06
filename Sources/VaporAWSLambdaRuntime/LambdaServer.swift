import AWSLambdaEvents
import AWSLambdaRuntime
import NIOPosix
import NIOCore
import Vapor

// MARK: LambdaServer

public protocol VaporLambda: ByteBufferLambdaHandler {
    init(app: Application) async throws

    var app: Application { get }
    static var requestSource: RequestSource { get }

    /// Used to set up globals such as logging, tracing, metrics, etc.
    static func bootstrap() async throws

    func configureApplication(_ app: Application) async throws
    func deconfigureApplication(_ app: Application) async throws

    func addRoutes(to app: Application) async throws
}

extension VaporLambda {
    public static func bootstrap() async throws {}

    public static func makeHandler(context: LambdaInitializationContext) -> EventLoopFuture<Self> {
        let promise = context.eventLoop.makePromise(of: Self.self)
        promise.completeWithTask {
            let app = try Application(.detect())
            let lambda = try await Self(app: app)

            do {
                try await lambda.configureApplication(app)
                try await lambda.addRoutes(to: app)
            } catch {
                app.logger.report(error: error)
                throw error
            }

            context.terminator.register(name: "Vapor App") { eventLoop in
                let promise = eventLoop.makePromise(of: Void.self)
                promise.completeWithTask {
                    try await lambda.deconfigureApplication(app)
                    app.shutdown()
                }
                return promise.futureResult
            }

            switch Self.requestSource.source {
            case .vapor:
                try app.start()
            case .apiGateway, .apiGatewayV2:
                // Fake server, not actually opening a socket
                app.servers.use { _ in
                    LambdaServer(shutdownPromise: context.eventLoop.makePromise())
                }

                try app.start()
            }

            return lambda
        }

        return promise.futureResult
    }

    public static func main() async throws {
        try await Self.bootstrap()
        let app = try Application(.detect())
        if Self.requestSource.source == .vapor {
            let lambda = try await Self(app: app)

            do {
                try await lambda.configureApplication(app)
                try await lambda.addRoutes(to: app)
            } catch {
                app.logger.report(error: error)
                try await lambda.deconfigureApplication(app)
                throw error
            }

            do {
                try await app.startup()
                try await app.running?.onStop.get()
                try await lambda.deconfigureApplication(app)
            } catch {
                try await lambda.deconfigureApplication(app)
                throw error
            }
        } else {
            let runtime = LambdaRuntimeFactory.makeRuntime(
                Self.self, 
                eventLoop: NIOSingletons.posixEventLoopGroup.any(),
                logger: app.logger
            )
            try await runtime.start().get()
            _ = try await runtime.shutdownFuture.get()
        }
    }

    public func handle(
        _ buffer: ByteBuffer,
        context: LambdaContext
    ) -> EventLoopFuture<ByteBuffer?> {
        do {
            switch Self.requestSource.source {
            case .vapor:
                preconditionFailure("Vapor Server hosted services do not handle lambdas")
            case .apiGateway:
                let lamdaRequest = try JSONDecoder().decode(
                    APIGatewayRequest.self,
                    from: buffer
                )
                let vaporRequest = try Request(
                    req: lamdaRequest,
                    in: context,
                    for: app
                )

                return app.responder.respond(to: vaporRequest)
                    .map(APIGatewayResponse.init)
                    .flatMapThrowing { response in
                        try JSONEncoder().encodeAsByteBuffer(
                            response,
                            allocator: context.allocator
                        )
                    }
            case .apiGatewayV2:
                let lamdaRequest = try JSONDecoder().decode(
                    APIGatewayV2Request.self,
                    from: buffer
                )
                let vaporRequest = try Vapor.Request(
                    req: lamdaRequest,
                    in: context,
                    for: app
                )

                return app.responder.respond(to: vaporRequest).flatMap {
                    APIGatewayV2Response.from(response: $0, in: context)
                }.flatMapThrowing { response in
                    try JSONEncoder().encodeAsByteBuffer(
                        response,
                        allocator: context.allocator
                    )
                }
            }
        } catch {
            return context.eventLoop.makeFailedFuture(error)
        }
    }
}

internal final class LambdaServer: Server {
    let shutdownPromise: EventLoopPromise<Void>

    init(shutdownPromise: EventLoopPromise<Void>) {
        self.shutdownPromise = shutdownPromise
    }

    var onShutdown: EventLoopFuture<Void> {
        shutdownPromise.futureResult
    }

    func start(address: BindAddress?) throws { }

    func shutdown() {
        shutdownPromise.succeed()
    }

    deinit {
        shutdownPromise.succeed()
    }
}

public struct RequestSource {
    internal enum _RequestSource {
        case vapor
        case apiGateway
        case apiGatewayV2
    }

    let source: _RequestSource

    public static func vapor() -> RequestSource {
        RequestSource(source: .vapor)
    }

    public static func apiGateway() -> RequestSource {
        RequestSource(source: .apiGateway)
    }

    public static func apiGatewayV2() -> RequestSource {
        RequestSource(source: .apiGatewayV2)
    }
}
