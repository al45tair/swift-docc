/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

public import Foundation
internal import ZLib

public struct ZLibError: Error {
    var message: String
}

public protocol ZipFileSink {
    var canSeek: Bool { get }

    /// Return the current position in the stream, or nil if not seekable
    func tell() throws -> Int?

    /// Seek to a location in the stream
    func seek(_ pos: Int) throws

    /// Write a fixed-width integer, in little-endian order
    func write<T: FixedWidthInteger>(_ x: T) throws

    /// Write a UTF-8 string
    func write(_ s: String) throws

    /// Write bytes
    func write(_ bytes: RawSpan) throws

    /// Close (optional)
    func close() throws
}

/// A ZipFileWriter can be used to generate a .zip file.
///
/// This generates UTF-8 zip files; it does not use Zip64 format.
public class ZipFileWriter<S: ZipFileSink> {

    var sink: S
    var comment: String?

    private struct FileInfo {
        var headerOffset: Int

        var name: String
        var date: Date
        var comment: String?

        var crc32: UInt32
        var compressedSize: Int
        var uncompressedSize: Int
    }

    private var files: [FileInfo] = []
    private var bytesWritten = 0
    private var buffer: UnsafeMutableRawBufferPointer

    public init(sink: consuming S, comment: String? = nil) {
        self.sink = sink
        self.comment = comment
        buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: 65536,
            alignment: 16
        )
    }

    deinit {
        buffer.deallocate()
    }

    public func addDirectory(
        named name: String,
        date: Date = .now,
        comment: String? = nil
    ) throws {
        try withFile(named: name + "/", date: date, comment: comment) { _ in }
    }

    public func withFile(
        named name: String,
        date: Date = .now,
        comment: String? = nil,
        generate: ((RawSpan) throws -> Void) throws -> Void
    ) throws {
        let headerOffset = bytesWritten

        // max compression, UTF-8 name, length at end if not seekable
        let flags: UInt16 = sink.canSeek ? 0x802 : 0x80a

        // Write the local header
        try sink.write(UInt32(0x0403_4b50))  // PK<03><04>
        try sink.write(UInt16(45))  // version 4.5 (we use Zip64)
        try sink.write(flags)  // max compression, UTF-8 name
        try sink.write(UInt16(8))  // DEFLATE compression
        try sink.write(date.dosFileTime)  // last modified time

        let crcPos = try sink.tell()
        try sink.write(UInt32(0))  // CRC32
        try sink.write(UInt32(0))  // Compressed size
        try sink.write(UInt32(0))  // Uncompressed size

        try sink.write(UInt16(name.utf8.count))  // Filename length
        try sink.write(UInt16(9))  // Extra field length

        bytesWritten += 30

        // Filename
        try sink.write(name)

        bytesWritten += name.utf8.count

        // Extra field
        try sink.write(UInt16(0x5455))  // UT - Extended Timestamp
        try sink.write(UInt16(5))  // Size
        try sink.write(UInt8(1))  // Only modification time
        try sink.write(Int32(date.timeIntervalSince1970))

        bytesWritten += 9

        // Compress the data and update the CRC
        var crc = crc32_z(0, nil, 0)
        var stream = z_stream()

        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil

        stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
        stream.avail_out = uInt(buffer.count)
        if deflateInit2(&stream, 9, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK {
            throw ZLibError(message: String(cString: stream.msg!))
        }

        try generate { (data: RawSpan) throws -> Void in
            try data.withUnsafeBytes { inbuf in
                // Update CRC
                crc = crc32_z(crc, inbuf.baseAddress, inbuf.count)

                // Compress this chunk
                stream.next_in = UnsafeMutablePointer(
                    mutating:
                        inbuf.baseAddress!.assumingMemoryBound(to: Bytef.self)
                )
                stream.avail_in = uInt(inbuf.count)

                while stream.avail_in != 0 {
                    let ret = deflate(&stream, Z_NO_FLUSH)

                    if ret == Z_STREAM_ERROR {
                        throw ZLibError(message: String(cString: stream.msg!))
                    }

                    if stream.avail_out == 0 {
                        try sink.write(buffer.bytes)
                        bytesWritten += buffer.count
                        stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
                        stream.avail_out = uInt(buffer.count)
                    }
                }
            }
        }

        while true {
            let ret = deflate(&stream, Z_FINISH)
            if ret != Z_OK && ret != Z_BUF_ERROR && ret != Z_STREAM_END {
                throw ZLibError(message: String(cString: stream.msg!))
            }

            let toFlush = buffer.count - Int(stream.avail_out)
            try sink.write(buffer.bytes.extracting(first: toFlush))
            bytesWritten += toFlush
            stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(buffer.count)

            if ret == Z_STREAM_END {
                break
            }
        }

        let ret = deflateEnd(&stream)
        if ret != Z_OK {
            throw ZLibError(message: String(cString: stream.msg!))
        }

        // Now update the CRC, compressed and uncompressed sizes, *or*
        // write the data descriptor if this stream is not seekable.
        let currentPos = try sink.tell()
        if let crcPos {
            try sink.seek(crcPos)
        } else {
            try sink.write(UInt32(0x0807_4b50))  // PK<07><08>
        }
        try sink.write(UInt32(crc))
        try sink.write(UInt32(stream.total_out))
        try sink.write(UInt32(stream.total_in))
        if crcPos != nil {
            try sink.seek(currentPos!)
        } else {
            bytesWritten += 16
        }

        // Add all of this to the list of files
        files.append(
            FileInfo(
                headerOffset: headerOffset,
                name: name,
                date: date,
                comment: comment,
                crc32: UInt32(crc),
                compressedSize: Int(stream.total_out),
                uncompressedSize: Int(stream.total_in)
            ))
    }

    public func close() throws {
        // max compression, UTF-8 name, length at end if not seekable
        let flags: UInt16 = sink.canSeek ? 0x802 : 0x80a
        let centralDirectoryOffset = bytesWritten

        // Write the central directory
        for file in files {
            try sink.write(UInt32(0x0201_4b50))  // PK<01><02>
            try sink.write(UInt16(45))  // version 4.5 made by
            try sink.write(UInt16(45))  // version 4.5 needed
            try sink.write(flags)  // max compression, UTF-8 name
            try sink.write(UInt16(8))  // DEFLATE compression
            try sink.write(file.date.dosFileTime)  // last modified time
            try sink.write(file.crc32)  // CRC32
            try sink.write(UInt32(file.compressedSize))  // Compressed size
            try sink.write(UInt32(file.uncompressedSize))  // Uncompressed size
            try sink.write(UInt16(file.name.utf8.count))  // Filename length
            try sink.write(UInt16(9))  // Extra field length

            if let comment = file.comment {
                try sink.write(UInt16(comment.utf8.count))
            } else {
                try sink.write(UInt16(0))
            }

            try sink.write(UInt16(0))  // Disk number start
            try sink.write(UInt16(0))  // Internal file attributes
            try sink.write(UInt32(0))  // External file attributes
            try sink.write(UInt32(file.headerOffset))  // Offset to local header

            bytesWritten += 46

            // Filename
            try sink.write(file.name)

            bytesWritten += file.name.utf8.count

            // Extra field
            try sink.write(UInt16(0x5455))  // UT - Extended Timestamp
            try sink.write(UInt16(5))  // Size
            try sink.write(UInt8(1))  // Only modification time
            try sink.write(Int32(file.date.timeIntervalSince1970))

            bytesWritten += 9

            // File comment
            if let comment = file.comment {
                try sink.write(comment)

                bytesWritten += comment.utf8.count
            }
        }

        let centralDirectorySize = UInt32(bytesWritten - centralDirectoryOffset)

        // Write the end of central directory record
        try sink.write(UInt32(0x0605_4b50))  // PK<05><06>
        try sink.write(UInt16(0))  // Disk 0
        try sink.write(UInt16(0))  // Directory disk 0
        try sink.write(UInt16(files.count))  // Entries on disk 0
        try sink.write(UInt16(files.count))  // Entries in total
        try sink.write(centralDirectorySize)  // Size of directory
        try sink.write(UInt32(centralDirectoryOffset))  // Offset to directory

        // Zip file comment
        if let comment {
            try sink.write(UInt16(comment.utf8.count))
            for elt in comment.utf8 {
                try sink.write(elt)
            }
        } else {
            try sink.write(UInt16(0))
        }

        try sink.close()
    }
}

// Provide default implementations of Sink methods
public extension ZipFileSink {
    func write<T: FixedWidthInteger>(_ x: T) throws {
        var maybeSwapped = x.littleEndian
        try withUnsafeBytes(of: &maybeSwapped) {
            try self.write($0.bytes)
        }
    }

    func write(_ s: String) throws {
        var sMutable = s
        try sMutable.withUTF8 {
            try self.write(UnsafeRawBufferPointer($0).bytes)
        }
    }

    func close() throws {
        // Dummy implementation
    }
}
