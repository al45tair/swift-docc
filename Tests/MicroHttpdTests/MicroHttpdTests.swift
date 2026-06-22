import Foundation
import Testing

@testable import MicroHttpd

struct NotFoundHandler: RequestHandler {
    func handle(request: Request, on connection: Connection) throws -> Bool {
        try connection.send(response: Response.notFound)
        return false
    }
}

struct HelloHandler: RequestHandler {
    func handle(request: Request, on connection: Connection) throws -> Bool {
        try connection.send(
            response: Response(
                status: 200,
                message: "OK",
                headers: [:],
                body: .text("Hello World!")
            )
        )
        return true
    }
}

let helloHtml = """
    <html>
        <head>
            <title>Hello World</title>
        </head>
        <body>
            <h1>Hello World!</h1>
            <p>Hello, this is a test.</p>
        </body>
    </html>
    """

struct HtmlHelloHandler: RequestHandler {
    func handle(request: Request, on connection: Connection) throws -> Bool {
        try connection.send(
            response: Response(
                status: 200,
                message: "OK",
                headers: [:],
                body: .html(helloHtml)
            )
        )
        return true
    }
}

struct HtmlHelloHandler2: RequestHandler {
    func handle(request: Request, on connection: Connection) throws -> Bool {
        let length = helloHtml.utf8.count + 2
        try connection.send(
            response: Response(
                status: 200,
                message: "OK",
                headers: ["Content-Length": "\(length)"],
                body: .none
            )
        )
        try connection.send(utf8: helloHtml)
        try connection.send(utf8: "\r\n")
        return true
    }
}

@Test func serverRespondsAndStops() async throws {
    let httpd = MicroHttpd(port: 8081, requestHandler: NotFoundHandler())

    Task.detached {
        try! httpd.serve()
    }

    let session = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "http://localhost:8081/")!)

    let (_, response) = try! await session.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        fatalError("response should be an httpResponse")
    }

    httpd.stop()

    #expect(httpResponse.statusCode == 404)
}

@Test func helloWorldServer() async throws {
    let httpd = MicroHttpd(port: 8082, requestHandler: HelloHandler())

    Task.detached {
        try! httpd.serve()
    }

    let session = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "http://localhost:8082/")!)

    for _ in 0..<5 {
        let (data, response) = try! await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            fatalError("response should be an httpResponse")
        }

        let body = String(decoding: data, as: UTF8.self)

        #expect(httpResponse.statusCode == 200)
        #expect(body == "Hello World!\r\n")
    }

    httpd.stop()
}

@Test func htmlHelloWorldServer() async throws {
    let httpd = MicroHttpd(port: 8083, requestHandler: HtmlHelloHandler())

    Task.detached {
        try! httpd.serve()
    }

    let session = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "http://localhost:8083/")!)

    for _ in 0..<5 {
        let (data, response) = try! await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            fatalError("response should be an httpResponse")
        }

        let body = String(decoding: data, as: UTF8.self)

        #expect(httpResponse.statusCode == 200)
        #expect(body == "\(helloHtml)\r\n")
    }

    httpd.stop()
}

@Test func htmlHelloWorldServer2() async throws {
    let httpd = MicroHttpd(port: 8084, requestHandler: HtmlHelloHandler2())

    Task.detached {
        try! httpd.serve()
    }

    let session = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "http://localhost:8084/")!)

    for _ in 0..<5 {
        let (data, response) = try! await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            fatalError("response should be an httpResponse")
        }

        let body = String(decoding: data, as: UTF8.self)

        #expect(httpResponse.statusCode == 200)
        #expect(body == "\(helloHtml)\r\n")
    }

    httpd.stop()
}

@Test func manyConnections() async throws {
    let httpd = MicroHttpd(port: 8085, requestHandler: HelloHandler())

    Task.detached {
        try! httpd.serve()
    }

    let session = URLSession(configuration: .default)
    let request = URLRequest(url: URL(string: "http://localhost:8085/")!)

    await withTaskGroup { group in
        for _ in 0..<10 {
            group.addTask {
                for _ in 0..<5 {
                    let (data, response) = try! await session.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        fatalError("response should be an httpResponse")
                    }

                    let body = String(decoding: data, as: UTF8.self)

                    #expect(httpResponse.statusCode == 200)
                    #expect(body == "Hello World!\r\n")
                }
            }
        }
    }

    httpd.stop()

}
