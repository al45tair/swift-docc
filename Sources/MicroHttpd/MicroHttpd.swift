/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

public import Foundation
import Synchronization

#if os(anyAppleOS)
    internal import Darwin
#elseif os(Linux)
    #if canImport(Musl)
        internal import Musl
    #else
        internal import Glibc
    #endif
#elseif os(Windows)
    public import WinSDK
    internal import ucrt
#else
    #error("You will need to add code for your platform")
#endif

public enum MicroHttpdError: Error {
    #if os(Windows)
        case win32Error(error: DWORD)
    #else
        case posixError(errno: CInt)
    #endif
    case prematureEndOfBody
    case expectedChunk
    case badChunk
    case chunkTooLong
    case expectedCRLF
    case lineTooLong
}

func throwSystemError() throws(MicroHttpdError) {
    #if os(Windows)
        let error = GetLastError()
        throw MicroHttpdError.win32Error(error: error)
    #else
        let error = errno
        throw MicroHttpdError.posixError(errno: error)
    #endif
}

let realSocket = socket

// This annoying nonsense is to deal with the fact that some
// constants are sometimes imported as `enum`s.
private func openRaw<T: RawRepresentable>(_ value: T) -> T.RawValue {
    return value.rawValue
}
private func openRaw<T>(_ value: T) -> T {
    return value
}

private func nonOptional<T>(_ value: T?) -> T {
    return value!
}
private func nonOptional<T>(_ value: T) -> T {
    return value
}

private func setsockopt<T>(
    _ socket: Socket,
    _ level: CInt,
    _ option: CInt,
    _ setting: T
) -> CInt {
    var theSetting = setting
    return withUnsafePointer(to: &theSetting) { ptr in
        setsockopt(socket, level, option, ptr, socklen_t(MemoryLayout<T>.size))
    }
}

private func bind<A>(
    _ socket: Socket,
    _ address: A
) -> CInt {
    var theAddress = address
    return withUnsafePointer(to: &theAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            bind(socket, ptr, socklen_t(MemoryLayout<A>.size))
        }
    }
}

private func connect<A>(
    _ socket: Socket,
    _ address: A
) -> CInt {
    var theAddress = address
    return withUnsafePointer(to: &theAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            connect(socket, ptr, socklen_t(MemoryLayout<A>.size))
        }
    }
}

private func accept<A>(
    _ socket: Socket,
    _ address: inout A
) -> Socket {
    var length = socklen_t(MemoryLayout<A>.size)
    return withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
            accept(socket, ptr, &length)
        }
    }
}

public struct Request {
    public var verb: String
    public var url: URL
    public var httpVersion: String
    public var headers: [String: String]
}

public struct Response: Error, CustomStringConvertible {
    public var status: Int
    public var message: String
    public var headers: [String: String]

    public enum Body: Sendable {
        /// Means that the request handler will send body data itself
        case none

        /// Respond with an empty body
        case empty

        /// Respond with a string body
        case text(String)

        /// Respond with an HTML body
        case html(String)
    }

    public var body: Body

    public init(status: Int,
                message: String,
                headers: [String:String] = [:],
                body: Body = .empty) {
        self.status = status
        self.message = message
        self.headers = headers
        self.body = body
    }

    public var description: String {
        return "HTTP/1.1 \(status) \(message)"
    }

    public static let badRequest = Response(
        status: 400,
        message: "Bad request",
        headers: [:],
        body: .text("400 Bad request")
    )
    public static let notFound = Response(
        status: 404,
        message: "Not found",
        headers: [:],
        body: .text("404 Not found")
    )
    public static let srvFail = Response(
        status: 500,
        message: "Internal server error",
        headers: [:],
        body: .text("500 Internal server error")
    )
}

public protocol RequestHandler: Sendable {
    func handle(
        request: Request,
        on connection: Connection
    ) throws -> Bool
}

public final class Connection {
    var port: UInt16
    var stream: SocketStream
    var remoteAddr: sockaddr_in

    var maxRequestSize: Int
    var requestHandler: any RequestHandler

    init(
        port: UInt16,
        socket: Socket, remoteAddr: sockaddr_in, maxRequestSize: Int,
        requestHandler: any RequestHandler
    ) {
        self.port = port
        self.stream = SocketStream(socket: socket, bufferSize: 65536)
        self.remoteAddr = remoteAddr
        self.maxRequestSize = maxRequestSize
        self.requestHandler = requestHandler

        log("Connected.")
    }

    enum State {
        case scanningRequestLine
        case scanningHeader
        case processingRequest
        case scanningChunkedRequestBody
    }

    var state: State = .scanningRequestLine

    var remainingBytesInThisChunk: Int? = nil

    // Eat remainingBytesInThisChunk bytes from the input
    func eatChunk() throws -> Bool {
        guard var remaining = remainingBytesInThisChunk else {
            return false
        }

        while remaining > 0 {
            let discarded = try stream.discard(byteCount: remaining)
            if discarded == 0 {
                return false
            }
            remaining -= discarded
        }

        remainingBytesInThisChunk = nil
        return true
    }

    public func log(_ message: String) {
        let remotePort = remoteAddr.sin_port.bigEndian
        print("\(Date.now) [\(port):\(remotePort)] \(message)")
    }

    func serve() {
        var verb: String = ""
        var urlString: String = ""
        var httpVersion: String = ""
        var headers: [String: String] = [:]

        do {
            while true {
                guard let line = try stream.readLine() else {
                    break
                }

                // Run the state machine
                switch state {
                case .scanningRequestLine:
                    let parts = line.split(separator: " ", maxSplits: 2)
                    if parts.count != 3
                        || (parts[2] != "HTTP/1.0"
                            && parts[2] != "HTTP/1.1")
                    {
                        log("Bad request line \"\(line)\"")
                        throw Response.badRequest
                    }

                    verb = String(parts[0])
                    urlString = String(parts[1])
                    httpVersion = String(parts[2])
                    headers.removeAll()
                    remainingBytesInThisChunk = nil

                    state = .scanningHeader
                    break
                case .scanningHeader:
                    // An empty line means we're in the request body
                    guard let firstChar = line.first else {
                        var chunked = false
                        if let transferEncoding = headers["Transfer-Encoding"] {
                            let encodings = transferEncoding.split(separator: ",")
                            for enc in encodings {
                                let encoding = enc.trimmingCharacters(in: .whitespaces)
                                switch encoding {
                                case "chunked": chunked = true
                                default:
                                    log("Unsupported Transfer-Encoding \"\(encoding)\"")
                                    throw Response.badRequest
                                }
                            }
                        }

                        if chunked {
                            state = .scanningChunkedRequestBody
                        } else if let contentLength = headers["Content-Length"] {
                            guard let length = Int(contentLength) else {
                                log("Bad Content-Length \"\(contentLength)\"")
                                throw Response.badRequest
                            }

                            if length > maxRequestSize {
                                log(
                                    "Content-Length (\(length)) over maximum request size \(maxRequestSize)"
                                )
                                throw Response.badRequest
                            }

                            state = .processingRequest
                            remainingBytesInThisChunk = length
                        } else {
                            state = .processingRequest
                            remainingBytesInThisChunk = 0
                        }

                        guard let url = URL(string: urlString) else {
                            log("Bad URL \"\(urlString)\"")
                            throw Response.badRequest
                        }

                        // Actually handle the request
                        let request = Request(
                            verb: verb,
                            url: url,
                            httpVersion: httpVersion,
                            headers: headers)

                        log("\(request.verb) \(request.url)")

                        let result = try requestHandler.handle(
                            request: request,
                            on: self)
                        if !result {
                            log("Closing connection.")
                            stream.close()
                            return
                        }

                        if try !eatChunk() {
                            log("Failed to skip body chunk.")
                            throw Response.badRequest
                        }

                        if state == .processingRequest {
                            state = .scanningRequestLine
                        }
                        break
                    }

                    if firstChar == " " || firstChar == "\t" {
                        // This is a continuation of the previous header line;
                        // per RFC9112 5.2, we don't support wrapped header lines.
                        log("Header line continuations are not supported (per RFC9112 5.2)")
                        throw Response.badRequest
                    }

                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count != 2 {
                        log("Bad header line \"\(line)\"")
                        throw Response.badRequest
                    }

                    let fieldName = String(parts[0])
                    let fieldValue = String(parts[1]).trimmingCharacters(in: .whitespaces)

                    // Check that there are no spaces/tabs in fieldName
                    // (see RFC9112 5.1, which says we must 400 this).
                    for char in fieldName.utf8 {
                        if char == 0x20 || char == 0x09 {
                            log("Spaces/tabs in header field \"\(fieldName)\"")
                            throw Response.badRequest
                        }
                    }

                    if fieldName == "Set-Cookie" {
                        // Since we are a server, we ignore Set-Cookie headers
                    } else if let currentValue = headers[fieldName] {
                        headers[fieldName] = "\(currentValue), \(fieldValue)"
                    } else {
                        headers[fieldName] = fieldValue
                    }

                case .processingRequest:
                    fatalError("We should never land in this state here.")

                case .scanningChunkedRequestBody:
                    let pieces = line.split(separator: ";")
                    if pieces.count < 1 {
                        log("Bad chunk header \"\(line)\"")
                        throw Response.badRequest
                    }

                    let lengthHex = pieces[0].trimmingCharacters(in: .whitespaces)
                    guard let length = Int(lengthHex, radix: 16) else {
                        log("Bad chunk length \"\(lengthHex)\"")
                        throw Response.badRequest
                    }

                    if length == 0 {
                        state = .scanningRequestLine
                    } else {
                        if length > maxRequestSize {
                            log(
                                "Chunk length (\(length)) is greater than maximum size (\(maxRequestSize))"
                            )
                            throw Response.badRequest
                        }

                        if try !eatChunk() {
                            log("Failed to skip body chunk.")
                            throw Response.badRequest
                        }

                        // Scan a line ending
                        var gotLineEnding = false
                        if let cr = try stream.readByte() {
                            if cr == 13 {
                                if let lf = try stream.readByte() {
                                    if lf == 10 {
                                        gotLineEnding = true
                                    }
                                }
                            } else if cr == 10 {
                                gotLineEnding = true
                            }
                        }

                        if !gotLineEnding {
                            log("Missing CR/LF after chunk")
                            throw Response.badRequest
                        }
                    }
                }
            }
        } catch let response as Response {
            try? send(response: response)
            log("Closing connection.")
            stream.close()
        } catch {
            try? send(response: Response.srvFail)
            log("Closing connection: \(error)")
            stream.close()
        }
    }

    /// Read from the body of the current request; will return an empty
    /// span when there is no more to read.
    public func read(into span: inout OutputRawSpan) throws {
        switch state {
        case .processingRequest:
            guard let remaining = remainingBytesInThisChunk,
                remaining > 0
            else {
                remainingBytesInThisChunk = nil
                span.removeAll()
                return
            }

            try stream.readBytes(into: &span, limit: remaining)

            remainingBytesInThisChunk = remaining - span.byteCount

        case .scanningChunkedRequestBody:
            if remainingBytesInThisChunk == nil {
                guard let line = try stream.readLine() else {
                    throw MicroHttpdError.expectedChunk
                }

                let pieces = line.split(separator: ";")
                if pieces.count < 1 {
                    throw MicroHttpdError.badChunk
                }

                let lengthHex = pieces[0].trimmingCharacters(in: .whitespaces)
                guard let length = Int(lengthHex, radix: 16) else {
                    throw MicroHttpdError.badChunk
                }

                if length == 0 {
                    state = .scanningRequestLine
                    span.removeAll()
                    return
                }

                if length > maxRequestSize {
                    throw MicroHttpdError.chunkTooLong
                }

                remainingBytesInThisChunk = length
            }

            guard let remaining = remainingBytesInThisChunk,
                remaining > 0
            else {
                remainingBytesInThisChunk = nil
                span.removeAll()
                return
            }

            try stream.readBytes(into: &span, limit: remaining)

            remainingBytesInThisChunk = remaining - span.byteCount

            if remainingBytesInThisChunk == 0 {
                // Scan a line ending
                var gotLineEnding = false
                if let cr = try stream.readByte() {
                    if cr == 13 {
                        if let lf = try stream.readByte() {
                            if lf == 10 {
                                gotLineEnding = true
                            }
                        }
                    } else if cr == 10 {
                        gotLineEnding = true
                    }
                }

                if !gotLineEnding {
                    throw MicroHttpdError.expectedCRLF
                }
            }

        case .scanningRequestLine:
            span.removeAll()
            return

        default:
            fatalError("Must not call Connection.read() in state \(state)")
        }
    }

    public func send(response: Response) throws {
        log("=> \(response.status) \(response.message)")

        var headers = response.headers
        switch response.body {
        case .none:
            break
        case .empty:
            headers["Content-Length"] = "0"
            break
        case .text(let string):
            headers["Content-Length"] = "\(string.utf8.count + 2)"
            headers["Content-Type"] = "text/plain; charset=utf-8"
        case .html(let string):
            headers["Content-Length"] = "\(string.utf8.count + 2)"
            headers["Content-Type"] = "text/html; charset=utf-8"
        }
        headers["Date"] = Date.now.httpDate

        let responseLine = "HTTP/1.1 \(response.status) \(response.message)\r\n"
        _ = try stream.send(responseLine)
        for (header, value) in headers {
            let headerLine = "\(header): \(value)\r\n"
            _ = try stream.send(headerLine)
        }
        _ = try stream.send("\r\n")

        switch response.body {
        case .none, .empty:
            break
        case .text(let string), .html(let string):
            _ = try stream.sendUTF8(string)
            _ = try stream.sendUTF8("\r\n")
        }
    }

    public func send(bytes: RawSpan) throws {
        _ = try stream.send(bytes)
    }

    public func send(latin1 string: String) throws {
        _ = try stream.send(string)
    }

    public func send(utf8 string: String) throws {
        _ = try stream.sendUTF8(string)
    }
}

/// A tiny, portable, HTTP server, written entirely in Swift; this is
/// designed to *only* ever bind to localhost, as it's intended exclusively
/// for debugging and testing purposes.
public final class MicroHttpd: @unchecked Sendable {
    var port: UInt16
    var listener: Socket = invalidSocket
    var maxRequestSize: Int
    var requestHandler: any RequestHandler

    let pleaseStop = Atomic<Bool>(false)

    public init(
        port: UInt16 = 8080, maxRequestSize: Int = 1_048_576,
        requestHandler: any RequestHandler
    ) {
        self.port = port
        self.maxRequestSize = maxRequestSize
        self.requestHandler = requestHandler
    }

    deinit {
        if listener != invalidSocket {
            #if os(Windows)
                closesocket(listener)
            #else
                close(listener)
            #endif
        }
    }

    var sockaddr: sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian

        // Doing this avoids problems with macros
        withUnsafeMutableBytes(of: &addr.sin_addr) { bytes in
            bytes[0] = 127
            bytes[1] = 0
            bytes[2] = 0
            bytes[3] = 1
        }

        return addr
    }

    public func stop() {
        print("Microhttpd at localhost:\(port) stopping")

        // To do this, we set `pleaseStop` to true, then connect,
        // which will make the `accept` call return at which point we can
        // check `pleaseStop`.
        pleaseStop.store(true, ordering: .releasing)

        let sock = socket(
            CInt(openRaw(AF_INET)),
            CInt(openRaw(SOCK_STREAM)),
            CInt(openRaw(IPPROTO_TCP)))
        defer {
            #if os(Windows)
                closesocket(sock)
            #else
                close(sock)
            #endif
        }

        if connect(sock, self.sockaddr) == -1 {
            print("microhttpd: failed to connect when trying to stop")
        }
    }

    public func serve() throws {
        listener = socket(
            CInt(openRaw(AF_INET)),
            CInt(openRaw(SOCK_STREAM)),
            CInt(openRaw(IPPROTO_TCP)))
        if listener == invalidSocket {
            try throwSystemError()
        }
        defer {
            #if os(Windows)
                closesocket(listener)
            #else
                close(listener)
            #endif
            listener = invalidSocket
        }

        if setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, CInt(1)) == -1 {
            try throwSystemError()
        }

        if bind(listener, self.sockaddr) == -1 {
            try throwSystemError()
        }

        if listen(listener, 16) == -1 {
            try throwSystemError()
        }

        print("MicroHttpd listening at localhost:\(port)")

        while true {
            var remoteAddr = sockaddr_in()
            let sock = accept(listener, &remoteAddr)

            if sock == invalidSocket {
                try throwSystemError()
            }

            if pleaseStop.load(ordering: .acquiring) {
                print("MicroHttpd at localhost:\(port) stopped")
                return
            }

            let connection = Connection(
                port: port,
                socket: sock,
                remoteAddr: remoteAddr,
                maxRequestSize: maxRequestSize,
                requestHandler: requestHandler
            )

            #if os(Windows)
                let thread = _beginthreadex(
                    nil, 0,
                    {
                        let ptr = UnsafeRawPointer($0!)
                        let conn = Unmanaged<Connection>.fromOpaque(ptr).takeRetainedValue()
                        conn.serve()
                        return 0
                    }, Unmanaged<Connection>.passRetained(connection).toOpaque(),
                    0, nil)
                if thread == 0 {
                    try throwSystemError()
                }
            #else
                #if os(macOS)
                    var thread: pthread_t? = nil
                #else
                    var thread = pthread_t()
                #endif
                let ret = pthread_create(
                    &thread, nil,
                    {
                        let conn = Unmanaged<Connection>.fromOpaque(nonOptional($0))
                            .takeRetainedValue()
                        conn.serve()
                        return nil
                    }, Unmanaged<Connection>.passRetained(connection).toOpaque())
                if ret != 0 {
                    try throwSystemError()
                }
                _ = pthread_detach(nonOptional(thread))
            #endif
        }
    }
}
