/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import MicroHttpd
import Foundation
import SwiftDocC

struct PreviewRequestHandler: RequestHandler, Sendable {

    var archiveRoot: URL
    var fileSystem: any ReadOnlyFileManagerProtocol

    var indexFiles: [String] = [
        "index.html",
        "index.htm",
        "index.txt",
        "index.md",
        "index.rst",
    ]
    var contentTypes: [String: String] = [
        "css": "text/css",
        "gif": "image/gif",
        "htm": "text/html",
        "html": "text/html",
        "jpeg": "image/jpeg",
        "jpg": "image/jpeg",
        "js": "text/javascript",
        "json": "application/json",
        "md": "text/markdown",
        "png": "image/png",
        "rst": "text/x-rst",
        "svg": "image/svg+xml",
        "txt": "text/plain",
    ]

    init(
        archiveRoot: URL,
        fileSystem: any ReadOnlyFileManagerProtocol
    ) {
        self.archiveRoot = archiveRoot
        self.fileSystem = fileSystem
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
        let parts = filename.split(separator: ".")
        if parts.count < 2 {
            return nil
        }
        return String(parts[parts.count - 1])
    }

    public func handle(
        request: Request,
        on connection: Connection
    ) throws -> Bool {
        // Check the path we've been given
        guard let path = normalizedPath(
                            request.url.path(percentEncoded: false)) else {
            connection.log("Unacceptable path \"\(request.url)\"")
            throw Response.badRequest
        }
        let sourceURL = archiveRoot.appending(
            path: path,
            directoryHint: .inferFromPath
        )

        // We only want GET or HEAD
        switch request.verb {
        case "GET", "HEAD":
            break
        default:
            try connection.send(response: Response.badRequest)
            return true
        }

        // Try to serve from the source URL
        var wasDir = false
        if try serve(from: sourceURL, for: request,
                     on: connection, wasDir: &wasDir) {
            return true
        }

        if wasDir {
            for index in indexFiles {
                let indexURL = sourceURL.appending(
                    path: index,
                    directoryHint: .notDirectory
                )
                if try serve(from: indexURL,
                             for: request,
                             on: connection,
                             wasDir: &wasDir) {
                    return true
                }
            }
        }

        try connection.send(response: Response.notFound)
        return true
    }

    func serve(
        from url: URL,
        for request: Request,
        on connection: Connection,
        wasDir: inout Bool
    ) throws -> Bool {
        if fileSystem.directoryExists(atPath: url.path) {
            wasDir = true
            return false
        }

        let content: Data
        do {
            content = try fileSystem.contents(of: url)
        } catch {
            return false
        }

        let contentType: String
        if let ext = getExtension(from: url.path),
            let mimeType = contentTypes[ext] {
            contentType = mimeType
        } else {
            contentType = "application/octet-string"
        }

        let headers: [String: String] = [
            "Content-Length": "\(content.count)",
            "Content-Type": contentType,
            "Cache-Control": "no-store, no-cache, must-revalidate, post-check=0, pre-check=0",
            "Pragma": "no-cache"
        ]

        let response = Response(
            status: 200,
            message: "OK",
            headers: headers,
            body: .none
        )

        _ = try connection.send(response: response)
        _ = try connection.send(bytes: content.bytes)

        return true
    }

}
