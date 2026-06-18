/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

package import Foundation

enum RamDiskError: Error {
    case badURL(URL)
    case fileNotFound(URL)
    case badDestination(URL)
    case fileAlreadyExists(URL)
    case notADirectory(URL)
    case notAFile(URL)
}

/// A simple FileManagerProtocol implementation that holds data in memory.
class RamDiskFileManager: FileManagerProtocol {
    class Item {
        enum Kind {
            case directory([String: Item])
            case file(Data)
        }

        var attributes: [FileAttributeKey: Any]
        var kind: Kind

        init(attributes: [FileAttributeKey: Any], kind: Kind) {
            self.attributes = attributes
            self.kind = kind
        }

        var isDirectory: Bool {
            switch kind {
            case .directory: return true
            case .file: return false
            }
        }

        var isFile: Bool {
            switch kind {
            case .directory: return false
            case .file: return true
            }
        }
    }

    var root = Item(attributes: [:], kind: .directory([:]))
    var cwd: String = "/"

    func normalized(path: String) -> [String]? {
        var normalized: [String] = []
        for piece in path.split(separator: "/") {
            if piece == "." {
                continue
            }
            if piece == ".." {
                if normalized.count == 0 {
                    return nil
                }

                normalized.removeLast()
                continue
            }
            normalized.append(String(piece))
        }
        return normalized
    }

    func item(at path: String) -> Item? {
        guard let normalizedPath = normalized(path: path) else {
            return nil
        }
        var item = root
        for piece in normalizedPath {
            switch item.kind {
            case .directory(let contents):
                guard let newItem = contents[piece] else {
                    return nil
                }
                item = newItem
            case .file:
                return nil
            }
        }
        return item
    }

    func parentAndName(of path: String) -> (Item, String)? {
        var item = root
        guard var normalizedPath = normalized(path: path) else {
            return nil
        }
        let name = normalizedPath.removeLast()
        for piece in normalizedPath {
            switch item.kind {
            case .directory(let contents):
                guard let newItem = contents[piece] else {
                    return nil
                }
                item = newItem
            case .file:
                return nil
            }
        }
        return (item, name)
    }

    public func contents(atPath path: String) -> Data? {
        guard let item = item(at: path) else {
            return nil
        }

        if case .file(let data) = item.kind {
            return data
        }

        return nil
    }

    public func contentsEqual(
        atPath path1: String,
        andPath path2: String
    ) -> Bool {
        return contents(atPath: path1) == contents(atPath: path2)
    }

    public var currentDirectoryPath: String {
        return cwd
    }

    public func fileExists(
        atPath path: String,
        isDirectory: UnsafeMutablePointer<ObjCBool>?
    ) -> Bool {
        guard let item = item(at: path) else {
            return false
        }

        if let isDirectory {
            isDirectory.pointee = ObjCBool(item.isDirectory)
        }

        return true
    }

    public func directoryExists(atPath path: String) -> Bool {
        guard let item = item(at: path) else {
            return false
        }

        return item.isDirectory
    }

    public func fileExists(atPath path: String) -> Bool {
        guard let item = item(at: path) else {
            return false
        }

        return item.isFile
    }

    func urlToPath(_ url: URL) throws -> String {
        if url.scheme != "file" {
            throw RamDiskError.badURL(url)
        }
        return url.path(percentEncoded: false)
    }

    func pathToURL(_ path: String) -> URL {
        return URL(filePath: path)
    }

    public func _copyItem(at: URL, to: URL) throws {
        let fromPath = try urlToPath(at)
        let toPath = try urlToPath(to)

        guard let source = item(at: fromPath) else {
            throw RamDiskError.fileNotFound(at)
        }
        guard let (destination, name) = parentAndName(of: toPath) else {
            throw RamDiskError.fileNotFound(to)
        }

        switch destination.kind {
        case .directory(var contents):
            contents[name] = source
            destination.kind = .directory(contents)
        case .file:
            throw RamDiskError.badDestination(to)
        }
    }

    public func moveItem(at: URL, to: URL) throws {
        let fromPath = try urlToPath(at)
        let toPath = try urlToPath(to)

        guard let (source, oldName) = parentAndName(of: fromPath) else {
            throw RamDiskError.fileNotFound(at)
        }
        guard let (destination, name) = parentAndName(of: toPath) else {
            throw RamDiskError.fileNotFound(to)
        }

        switch source.kind {
        case .directory(var contents):
            guard let item = contents.removeValue(forKey: oldName) else {
                throw RamDiskError.fileNotFound(at)
            }
            switch destination.kind {
            case .directory(var destContents):
                destContents[name] = item
                destination.kind = .directory(destContents)
                source.kind = .directory(contents)
            case .file:
                throw RamDiskError.badDestination(to)
            }
        case .file:
            throw RamDiskError.fileNotFound(at)
        }
    }

    public func createDirectory(
        at: URL,
        withIntermediateDirectories: Bool,
        attributes: [FileAttributeKey: Any]?
    ) throws {
        var item = root
        guard var normalizedPath = normalized(path: try urlToPath(at)) else {
            throw RamDiskError.badURL(at)
        }
        let name = normalizedPath.removeLast()
        for piece in normalizedPath {
            switch item.kind {
            case .directory(var contents):
                if let newItem = contents[piece] {
                    item = newItem
                } else if withIntermediateDirectories {
                    let newItem = Item(
                        attributes: attributes ?? [:],
                        kind: .directory([:]))
                    contents[piece] = newItem
                    item.kind = .directory(contents)
                } else {
                    throw RamDiskError.fileNotFound(at)
                }

            case .file:
                throw RamDiskError.fileAlreadyExists(at)
            }
        }
        switch item.kind {
        case .directory(var contents):
            if contents[name] != nil {
                throw RamDiskError.fileAlreadyExists(at)
            } else {
                let newItem = Item(
                    attributes: attributes ?? [:],
                    kind: .directory([:]))
                contents[name] = newItem
                item.kind = .directory(contents)
            }
        case .file:
            throw RamDiskError.fileAlreadyExists(at)
        }
    }

    public func removeItem(at: URL) throws {
        guard let (parent, name) = parentAndName(of: try urlToPath(at)) else {
            throw RamDiskError.fileNotFound(at)
        }
        switch parent.kind {
        case .directory(var contents):
            guard contents.removeValue(forKey: name) != nil else {
                throw RamDiskError.fileNotFound(at)
            }
            parent.kind = .directory(contents)

        case .file:
            throw RamDiskError.fileNotFound(at)
        }
    }

    public func contentsOfDirectory(atPath path: String) throws -> [String] {
        guard let item = item(at: path) else {
            throw RamDiskError.fileNotFound(pathToURL(path))
        }
        guard case .directory(let contents) = item.kind else {
            throw RamDiskError.notADirectory(pathToURL(path))
        }

        return Array(contents.keys)
    }

    public func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> [URL] {
        guard let item = item(at: try urlToPath(url)) else {
            throw RamDiskError.fileNotFound(url)
        }
        guard case .directory(let contents) = item.kind else {
            throw RamDiskError.notADirectory(url)
        }

        return contents.keys.map { URL(string: $0, relativeTo: url)! }
    }

    public func uniqueTemporaryDirectory() -> URL {
        let base64 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"
        while true {
            let name = String((0..<32).map { _ in base64.randomElement()! })
            let path = "/tmp/" + name
            guard item(at: path) != nil else {
                return pathToURL(path)
            }
        }
    }

    public func createFile(at url: URL, contents: Data) throws {
        try createFile(at: url, contents: contents, options: .atomic)
    }

    public func contents(of url: URL) throws -> Data {
        guard let item = item(at: try urlToPath(url)) else {
            throw RamDiskError.fileNotFound(url)
        }
        switch item.kind {
        case .file(let data):
            return data
        case .directory:
            throw RamDiskError.notAFile(url)
        }
    }

    public func createFile(
        at url: URL,
        contents data: Data,
        options: NSData.WritingOptions?
    ) throws {
        guard let (parent, name) = parentAndName(of: try urlToPath(url)) else {
            throw RamDiskError.fileNotFound(url)
        }
        switch parent.kind {
        case .directory(var contents):
            if let options, options.contains(.withoutOverwriting) {
                if contents[name] != nil {
                    throw RamDiskError.fileAlreadyExists(url)
                }
            }
            contents[name] = Item(attributes: [:], kind: .file(data))
        case .file:
            throw RamDiskError.fileAlreadyExists(url)
        }
    }

    public func contentsOfDirectory(
        at url: URL,
        options: FileManager.DirectoryEnumerationOptions
    ) throws -> (files: [URL], directories: [URL]) {
        guard let item = item(at: try urlToPath(url)) else {
            throw RamDiskError.fileNotFound(url)
        }
        guard case .directory(let contents) = item.kind else {
            throw RamDiskError.notADirectory(url)
        }

        var files: [URL] = []
        var directories: [URL] = []

        for (name, item) in contents {
            switch item.kind {
            case .file:
                files.append(URL(string: name, relativeTo: url)!)
            case .directory:
                directories.append(URL(string: name, relativeTo: url)!)
            }
        }

        return (files: files, directories: directories)
    }
}
