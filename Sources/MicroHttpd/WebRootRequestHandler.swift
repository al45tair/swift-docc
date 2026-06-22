/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

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

#if canImport(FoundationEssentials)
    import FoundationEssentials
#else
    import Foundation
#endif

#if os(Windows)
    private func GetFileAttributes(_ path: String) -> DWORD {
        return path.withCString(encodedAs: UTF16.self) { lpszPath in
            GetFileAttributesW(lpszPath)
        }
    }

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
#endif

public struct WebRootRequestHandler: RequestHandler, Sendable {
    var webRoot: String
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

    public init(webRoot: String) {
        self.webRoot = webRoot
    }

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

    public func handle(
        request: Request,
        on connection: Connection
    ) throws -> Bool {
        guard let path = normalizedPath(request.url.path(percentEncoded: false)) else {
            connection.log("Unacceptable path \"\(request.url)\"")
            throw Response.badRequest
        }
        let tryPath = "\(webRoot)/\(path)"

        switch request.verb {
        case "GET", "HEAD":
            break
        default:
            try connection.send(response: Response.badRequest)
            return true
        }

        var wasDir = false
        if try serve(path: tryPath, for: request, on: connection, wasDir: &wasDir) {
            return true
        }

        if wasDir {
            for index in indexFiles {
                if try serve(
                    path: "\(tryPath)/\(index)",
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

    func serve(path: String, for request: Request, on connection: Connection, wasDir: inout Bool)
        throws -> Bool
    {
        #if os(Windows)
            let dwAttrs = GetFileAttributes(path)
            if dwAttrs == INVALID_FILE_ATTRIBUTES {
                return false
            }
            if (dwAttrs & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0 {
                wasDir = true
                return false
            }

            let handle = CreateFile(
                path,
                DWORD(GENERIC_READ),
                DWORD(FILE_SHARE_READ),
                nil,
                DWORD(OPEN_EXISTING),
                0,
                nil
            )
            if handle == INVALID_HANDLE_VALUE {
                return false
            }
            defer {
                CloseHandle(handle)
            }

            var liSize = LARGE_INTEGER()
            if !GetFileSizeEx(handle, &liSize) {
                let error = GetLastError()
                throw MicroHttpdError.win32Error(error: error)
            }
            let size = Int(liSize.QuadPart)

            var ftLastWrite = FILETIME()
            if !GetFileTime(handle, nil, nil, &ftLastWrite) {
                let error = GetLastError()
                throw MicroHttpdError.win32Error(error: error)
            }

            let lastModified = Date(fileTime: ftLastWrite)
        #else
            // Open the file/directory
            let fd = open(path, O_RDONLY)
            if fd < 0 {
                return false
            }
            defer {
                close(fd)
            }

            // Get the file attributes
            var st = stat()
            if fstat(fd, &st) < 0 {
                return false
            }

            #if os(macOS) || os(iOS)
                let lastModified = Date(timespec: st.st_mtimespec)
            #elseif os(Linux)
                let lastModified = Date(timespec: st.st_mtim)
            #else
                let lastModified = Date(time: st.st_mtime)
            #endif

            // Ignore things that are not regular files
            if (st.st_mode & S_IFMT) != S_IFREG {
                wasDir = (st.st_mode & S_IFMT) == S_IFDIR
                return false
            }

            let size = st.st_size
        #endif

        var headers: [String: String] = [
            "Content-Length": "\(size)",
            "Last-Modified": "\(lastModified.httpDate)",
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
            #if os(Windows)
                var dwRead: DWORD = 0
                let ret = ReadFile(
                    handle, buffer.baseAddress, DWORD(buffer.count),
                    &dwRead, nil)
                if !ret {
                    let error = GetLastError()
                    if error == ERROR_HANDLE_EOF {
                        return true
                    }
                    throw MicroHttpdError.win32Error(error: error)
                }

                let count = Int(dwRead)
            #else
                let count = read(fd, buffer.baseAddress, buffer.count)
                if count < 0 {
                    throw MicroHttpdError.posixError(errno: errno)
                }
            #endif

            if count == 0 {
                return true
            }

            let chunk = UnsafeRawBufferPointer(rebasing: buffer[0..<count])
            _ = try connection.send(bytes: chunk.bytes)
        }
    }
}
