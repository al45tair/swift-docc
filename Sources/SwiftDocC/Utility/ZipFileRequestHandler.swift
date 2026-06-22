/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

internal import ZLib
public import MicroHttpd

#if os(anyAppleOS)
    internal import Darwin
#elseif os(Linux)
    #if canImport(Musl)
        internal import Musl
    #else
        internal import Glibc
    #endif
#elseif os(Windows)
    internal import WinSDK
#else
    #error("You will need to add code for your platform")
#endif

#if os(Windows)
    private func CreateFile(
        _ path: String,
        _ dwDesiredAccess: DWORD,
        _ dwShareMode: DWORD,
        _ lpSecurityAttributes: LPSECURITY_ATTRIBUTES?,
        _ dwCreationDisposition: DWORD,
        _ dwFlagsAndAttributes: DWORD,
        _ hTemplateFile: HANDLE?
    ) -> HANDLE {
        return path.withCString(encodedAs: UTF16.self) { lpszPath in
            CreateFileW(
                lpszPath, dwDesiredAccess, dwShareMode,
                lpSecurityAttributes, dwCreationDisposition,
                dwFlagsAndAttributes, hTemplateFile)
        }
    }

    struct OnDiskZipFileSource: ZipFileSource {
        var handle: HANDLE
        var length: Int

        init(path: String) throws {
            handle = CreateFile(
                path: path,
                dwDesiredAccess: DWORD(GENERIC_READ),
                dwShareMode: DWORD(FILE_SHARE_READ),
                lpSecurityAttributes: nil,
                dwCreationDisposition: DWORD(OPEN_EXISTING),
                dwFlagsAndAttributes: DWORD(FILE_FLAG_OVERLAPPED),
                hTemplateFile: nil)
            if handle == INVALID_HANDLE_VALUE {
                let error = GetLastError()
                throw MicroHttpdError.win32Error(error: error)
            }

            var liSize = LARGE_INTEGER()
            if !GetFileSizeEx(handle, &liSize) {
                CloseHandle(handle)
                handle = INVALID_HANDLE_VALUE
                let error = GetLastError()
                throw MicroHttpdError.win32Error(error: error)
            }

            length = Int(liSize.QuadPart)
        }

        func read(from offset: Int, into span: inout OutputRawSpan) throws {
            span.withUnsafeMutableBytes { (bytes, count: inout Int) -> Void in
                var dwRead: DWORD = 0
                var ovl = OVERLAPPED()
                ovl.Offset = DWORD(truncatingIfNeeded: offset)
                ovl.OffsetHigh = DWORD(truncatingIfNeeded: offset >> 32)

                try withUnsafeMutablePointer(to: &ovl) { lpOverlapped in
                    let ret = ReadFile(
                        handle, bytes.baseAddress, DWORD(bytes.count),
                        nil, lpOverlapped)
                    if !ret {
                        let error = GetLastError()
                        if error != ERROR_IO_PENDING {
                            throw MicroHttpdError.win32Error(error: error)
                        }
                    }

                    let result = GetOverlappedResult(handle, lpOverlapped, &dwRead, true)
                    if !result {
                        let error = GetLastError()
                        throw MicroHttpdError.win32Error(error: error)
                    }
                }

                count = Int(dwRead)
            }
        }

        func close() throws {
            if handle != INVALID_HANDLE_VALUE {
                CloseHandle(handle)
                handle = INVALID_HANDLE_VALUE
            }
        }
    }
#else
    private let realClose = close

    struct OnDiskZipFileSource: ZipFileSource {
        var fd: CInt
        var length: Int

        init(path: String) throws {
            fd = open(path, O_RDONLY)
            if fd == -1 {
                let error = errno
                throw MicroHttpdError.posixError(errno: error)
            }

            let len = lseek(fd, 0, SEEK_END)
            if len < 0 {
                let error = errno
                throw MicroHttpdError.posixError(errno: error)
            }
            length = Int(len)
        }

        func read(from offset: Int, into span: inout OutputRawSpan) throws {
            try span.withUnsafeMutableBytes { (bytes, count: inout Int) -> Void in
                let done = pread(fd, bytes.baseAddress, bytes.count, off_t(offset))
                if done == -1 {
                    let error = errno
                    throw MicroHttpdError.posixError(errno: error)
                }
                count = done
            }
        }

        func close() throws {
            if realClose(fd) == -1 {
                let error = errno
                throw MicroHttpdError.posixError(errno: error)
            }
        }
    }
#endif

public struct ZipFileRequestHandler: RequestHandler, Sendable {
    var reader: ZipFileReader<OnDiskZipFileSource>

    var indexFiles: [String] = [
        "index.html",
        "index.htm",
        "index.txt",
        "index.md",
        "index.rst",
    ]
    var contentTypes: [String: String] = [
        "html": "text/html",
        "htm": "text/html",
        "txt": "text/plain",
        "md": "text/markdown",
        "rst": "text/x-rst",
        "js": "text/javascript",
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
    ]

    func normalizedPath(_ path: String) -> String? {
        let pieces = path.split(separator: "/")
        var normalizedPieces: [Substring] = []

        for piece in pieces {
            if piece == "." {
                continue
            }
            if piece == ".." {
                if normalizedPieces.count > 0 {
                    normalizedPieces.removeLast()
                }
                continue
            }
            normalizedPieces.append(piece)
        }

        return normalizedPieces.joined(separator: "/")
    }

    func getExtension(from path: String) -> String? {
        let filename: Substring
        if let lastSep = path.lastIndex(of: "/") {
            filename = path[path.index(after: lastSep)...]
        } else {
            filename = path[...]
        }
        let parts = filename.split(separator: ".", maxSplits: 1)
        if parts.count != 2 {
            return nil
        }
        return String(parts[1])
    }

    public init(path: String) throws {
        reader = try ZipFileReader(source: try OnDiskZipFileSource(path: path))
    }

    public func handle(
        request: Request,
        on connection: Connection
    ) throws -> Bool {
        guard let path = normalizedPath(request.url.path(percentEncoded: false)) else {
            connection.log("Unacceptable path \"\(request.url)\"")
            throw Response.badRequest
        }

        switch request.verb {
        case "GET", "HEAD":
            break
        default:
            try connection.send(response: Response.badRequest)
            return true
        }

        var wasDir = false
        if try serve(path: path, for: request, on: connection, wasDir: &wasDir) {
            return true
        }

        if wasDir {
            for index in indexFiles {
                if try serve(
                    path: "\(path)/\(index)",
                    for: request,
                    on: connection,
                    wasDir: &wasDir)
                {
                    return true
                }
            }
        }

        try connection.send(response: Response.notFound)
        return true
    }

    func serve(
        path: String,
        for request: Request,
        on connection: Connection,
        wasDir: inout Bool
    ) throws -> Bool {
        do {
            let theFile = try reader.open(path: path)

            var headers: [String: String] = [
                "Content-Length": "\(theFile.length)",
                "Last-Modified": "\(theFile.timestamp.httpDate)",
            ]

            // Try to set Content-Type from the extension
            if let ext = getExtension(from: path),
                let contentType = contentTypes[ext]
            {
                headers["Content-Type"] = contentType
            }

            if request.verb == "HEAD" {
                return true
            }

            let buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: 65536,
                alignment: 16)
            defer {
                buffer.deallocate()
            }

            let response = Response(
                status: 200,
                message: "OK",
                headers: headers,
                body: .none
            )

            _ = try connection.send(response: response)

            // Now send the data
            while true {
                var span = OutputRawSpan(buffer: buffer, initializedCount: 0)
                try theFile.read(into: &span)
                if span.byteCount == 0 {
                    return true
                }
                _ = try connection.send(bytes: span.bytes)
            }
        } catch ZipFileError.fileNotFound {
            return false
        } catch ZipFileError.itemIsADirectory {
            wasDir = true
            return false
        }
    }
}
