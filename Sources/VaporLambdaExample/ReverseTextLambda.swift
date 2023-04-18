import Vapor
import VaporAWSLambdaRuntime

struct TextBody: Content {
    let text: String
}

@main
struct ReverseTextLambda: VaporLambda {
    let app: Application
    static var requestSource: RequestSource {
        if Environment.get("HOST_LAMBDA") == "1" {
            return .vapor()
        } else {
            #if os(macOS)
            if Environment.get("LOCAL_LAMBDA_SERVER_ENABLED") == nil {
                print("Set `LOCAL_LAMBDA_SERVER_ENABLED=true` to host the lambda locally")
            }
            #endif

            return .apiGatewayV2()
        }
    }

    func configureApplication(_ app: Application) async throws { }
    func deconfigureApplication(_ app: Application) async throws { }

    func addRoutes(to app: Application) async throws {
        app.get { _ in
            return "Hello"
        }

        app.post { req -> String in
            let body = try req.content.decode(TextBody.self)
            return String(body.text.reversed())
        }
    }
}
