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

#if os(Windows)
    typealias Socket = SOCKET
    let invalidSocket = Socket(INVALID_SOCKET)
#else
    typealias Socket = CInt
    let invalidSocket: Socket = -1
#endif

#if os(Windows)
    typealias sa_family_t = ADDRESS_FAMILY
    private let realClose = closesocket
    private func realRecv(
        _ s: SOCKET, _ buf: UnsafeMutableRawPointer?,
        _ len: Int, _ flags: CInt
    ) -> Int {
        return Int(recv(s, buf?.assumingMemoryBound(to: CChar.self), CInt(len), flags))
    }
    private func realSend(
        _ s: SOCKET, _ buf: UnsafeRawPointer?,
        _ len: Int, _ flags: CInt
    ) -> Int {
        return Int(send(s, buf?.assumingMemoryBound(to: CChar.self), CInt(len), flags))
    }
#else
    private let realClose = close
    private func realRecv(
        _ s: CInt, _ buf: UnsafeMutableRawPointer?,
        _ len: Int, _ flags: CInt
    ) -> Int {
        var ret: Int
        repeat {
            ret = recv(s, buf, len, flags)
        } while ret == -1 && errno == EINTR
        return ret
    }
    private func realSend(
        _ s: CInt, _ buf: UnsafeRawPointer?,
        _ len: Int, _ flags: CInt
    ) -> Int {
        var ret: Int
        repeat {
            ret = send(s, buf, len, flags)
        } while ret == -1 && errno == EINTR
        return ret
    }
#endif

struct SocketStream: ~Copyable {
    /// The underlying socket
    var socket: Socket

    /// Our ring buffer storage
    var storage: UnsafeMutableRawBufferPointer

    /// The number of bytes in the buffer
    var count: Int

    /// The read pointer
    var readPtr: Int

    /// The write pointer
    var writePtr: Int

    /// The states for the line ending state machine
    enum LineState {
        case start  // We have yet to see a CR
        case seenCR  // The last character was a CR
        case foundLine  // We've found the next line ending
    }

    /// The line ending state
    var lineState: LineState

    /// The line ending state machine's lookahead pointer
    var linePtr: Int

    /// Points at the next line ending, if any
    var lineEndPtr: Int

    /// Construct a new SocketStream.
    ///
    /// - Parameters:
    ///   - socket:     The file descriptor for the socket.
    ///   - bufferSize: The size of the input ring buffer.
    ///
    init(socket: Socket, bufferSize: Int) {
        self.socket = socket
        self.storage = UnsafeMutableRawBufferPointer.allocate(
            byteCount: bufferSize,
            alignment: 16
        )
        self.count = 0
        self.readPtr = 0
        self.writePtr = 0

        self.lineState = .start
        self.linePtr = 0
        self.lineEndPtr = 0
    }

    deinit {
        if self.socket != invalidSocket {
            _ = realClose(self.socket)
        }
        storage.deallocate()
    }

    mutating func close() {
        if self.socket != invalidSocket {
            _ = realClose(self.socket)
            socket = invalidSocket
        }
    }

    /// Read bytes from the socket into an output span
    func rawRead(into span: inout OutputRawSpan) throws {
        try span.withUnsafeMutableBytes { (buffer, bufSize: inout Int) -> Void in
            let ret = realRecv(socket, buffer.baseAddress, buffer.count, 0)
            if ret == -1 {
                try throwSystemError()
            }
            bufSize = Int(ret)
        }
    }

    /// Read more bytes into the buffer, or throw an error on failure.
    ///
    /// - Parameters:
    ///   - maxBytes: The maximum number of bytes to read.
    ///
    mutating func fillBuffer(maxBytes: Int? = nil) throws -> Bool {
        let freeSpace = storage.count - count
        let spaceAfterWritePtr = storage.count - writePtr
        let todo: Int

        if let maxBytes {
            if count >= maxBytes {
                return false
            }
            todo = min(freeSpace, spaceAfterWritePtr, maxBytes)
        } else {
            todo = min(freeSpace, spaceAfterWritePtr)
        }

        let chunk = UnsafeMutableRawBufferPointer(
            rebasing:
                storage[writePtr..<writePtr + todo]
        )
        var span = OutputRawSpan(buffer: chunk, initializedCount: 0)
        try rawRead(into: &span)

        writePtr += span.byteCount
        count += span.byteCount

        return span.byteCount != 0
    }

    /// Read a byte.
    ///
    /// As a side effect, this function will reset the line ending state
    /// machine.
    ///
    mutating func readByte() throws -> UInt8? {
        if count == 0 {
            _ = try fillBuffer()
        }
        let byte = storage[readPtr]
        count -= 1
        readPtr += 1
        if readPtr == storage.count {
            readPtr = 0
        }

        resetLineState()

        return byte
    }

    /// Read multiple bytes into an `OutputSpan`.
    ///
    /// This function will read *up to* the number of bytes that the
    /// `OutputSpan` has storage for, but at most the number of bytes that
    /// are presently in the ring buffer.
    ///
    /// As a side effect, this function will reset the line ending state
    /// machine.
    ///
    /// - Parameters:
    ///   - into span: The span to read into.
    ///   - limit:     If set, restrict the number of bytes returned to
    ///                no more than `limit`, in spite of the size of the
    ///                span.  This exists to avoid having to create a new
    ///                span of a different size.
    ///
    mutating func readBytes(
        into span: inout OutputRawSpan,
        limit: Int? = nil
    ) throws {
        if count == 0 {
            _ = try fillBuffer()
        }
        span.withUnsafeMutableBytes { (buffer, bufSize: inout Int) -> Void in
            var pos = 0
            var remaining = min(count, buffer.count)
            if let limit {
                remaining = min(remaining, limit)
            }
            bufSize = remaining
            while remaining > 0 {
                let todo = min(remaining, storage.count - readPtr)
                let from = UnsafeRawBufferPointer(
                    rebasing:
                        storage[readPtr..<readPtr + todo]
                )
                let to = UnsafeMutableRawBufferPointer(
                    rebasing:
                        buffer[pos..<pos + todo]
                )
                to.copyMemory(from: from)

                count -= todo
                readPtr += todo
                pos += todo
                if readPtr == storage.count {
                    readPtr = 0
                }
                remaining -= todo
            }
        }

        resetLineState()
    }

    /// Discard bytes from the stream.
    ///
    /// - Parameters:
    ///   - byteCount: The number of bytes to discard.
    ///
    /// - Returns the number of bytes actually discarded, which may be
    ///   lower than the number requested.
    ///
    mutating func discard(byteCount toDiscard: Int) throws -> Int {
        if count == 0 {
            _ = try fillBuffer()
        }
        let done = min(count, toDiscard)
        var remaining = done
        while remaining > 0 {
            let todo = min(remaining, storage.count - readPtr)

            count -= todo
            remaining -= todo
            readPtr += todo
            if readPtr == storage.count {
                readPtr = 0
            }
        }
        return done
    }

    /// Reset the line ending state machine.
    mutating func resetLineState() {
        linePtr = readPtr
        lineState = .start
        lineEndPtr = 0
    }

    /// Look for the next line ending, and remember where we got to so we
    /// don't repeat this work.
    ///
    mutating func findLineEnding() -> Bool {
        if lineState == .foundLine {
            return true
        }

        // Work out how close to the end we are
        var remaining = count
        if linePtr >= readPtr {
            remaining -= linePtr - readPtr
        } else {
            remaining -= (storage.count - readPtr) + linePtr
        }

        while remaining > 0 {
            switch lineState {
            case .start:
                if storage[linePtr] == 13 {
                    lineState = .seenCR
                    lineEndPtr = linePtr
                }
                if storage[linePtr] == 10 {
                    lineState = .foundLine
                    lineEndPtr = linePtr
                    return true
                }
                break
            case .seenCR:
                if storage[linePtr] == 10 {
                    lineState = .foundLine
                    return true
                }
            case .foundLine:
                fatalError("It should be impossible to get here")
            }

            linePtr += 1
            if linePtr == storage.count {
                linePtr = 0
            }
            remaining -= 1
        }

        return false
    }

    /// Read a line.
    ///
    /// Tries to read a whole line from the ring buffer.  If we can't find
    /// a line ending in the buffer, and it isn't already full, this function
    /// will fetch more data.
    mutating func readLine() throws -> String? {
        while !findLineEnding() && count < storage.count {
            if try !fillBuffer() {
                return nil
            }
        }
        if !findLineEnding() {
            throw MicroHttpdError.lineTooLong
        }

        let line: String
        if lineEndPtr >= readPtr {
            let bytes = storage[readPtr..<lineEndPtr]
            line = String(decoding: bytes, as: ISO8859_1.self)
            count -= bytes.count
            readPtr = lineEndPtr
            if readPtr == storage.count {
                readPtr = 0
            }
        } else {
            // We've wrapped around the end of the buffer
            let firstChunk = storage[readPtr..<storage.count]
            let secondChunk = storage[0..<lineEndPtr]

            let firstString = String(
                decoding: firstChunk,
                as: ISO8859_1.self)
            let secondString = String(
                decoding: secondChunk,
                as: ISO8859_1.self)

            line = firstString + secondString
            count -= firstChunk.count + secondChunk.count
            readPtr = lineEndPtr
            if readPtr == storage.count {
                readPtr = 0
            }
        }

        // At this point readPtr is either looking at CR/LF or just LF;
        // skip the line ending
        if storage[readPtr] == 10 {
            readPtr += 1
            count -= 1
        } else {
            readPtr += 2
            count -= 2
        }
        if readPtr == storage.count {
            readPtr = 0
        }

        resetLineState()

        return line
    }

    func send(_ span: RawSpan) throws -> Bool {
        return try span.withUnsafeBytes { buffer in
            var pos = 0
            var remaining = buffer.count
            while remaining > 0 {
                let from = UnsafeRawBufferPointer(
                    rebasing:
                        buffer[pos..<buffer.count]
                )
                let ret = realSend(socket, from.baseAddress, from.count, 0)
                if ret == -1 {
                    try throwSystemError()
                }
                if ret == 0 {
                    return false
                }
                pos += Int(ret)
                remaining -= Int(ret)
            }
            return true
        }
    }

    func send(_ s: String) throws -> Bool {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count)
        let _ = transcode(
            s.utf8.makeIterator(),
            from: UTF8.self,
            to: ISO8859_1.self,
            stoppingOnError: false,
            into: { bytes.append($0) }
        )
        return try bytes.withUnsafeBytes { buffer in
            return try send(buffer.bytes)
        }
    }

    func sendUTF8(_ s: String) throws -> Bool {
        if #available(macOS 26, iOS 26, *) {
            return try send(s.utf8.span.bytes)
        } else {
            let bytes = Array(s.utf8)
            return try bytes.withUnsafeBytes { buffer in
                return try send(buffer.bytes)
            }
        }
    }
}
