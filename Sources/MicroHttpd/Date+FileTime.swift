/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

#if os(anyAppleOS)
    public import Darwin
#elseif os(Linux)
    #if canImport(Musl)
        public import Musl
    #else
        public import Glibc
    #endif
#elseif os(Windows)
    public import WinSDK
#else
    #error("You will need to add code for your platform")
#endif

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

// These are just for testing, so we can run the tests on every platform
#if os(Windows)
    public struct timespec {
        var tv_sec: CLong
        var tv_nsec: CLong
    }
#else
    public struct FILETIME {
        var dwLowDateTime: UInt32
        var dwHighDateTime: UInt32

        init() {
            dwLowDateTime = 0
            dwHighDateTime = 0
        }

        init(dwLowDateTime: UInt32, dwHighDateTime: UInt32) {
            self.dwLowDateTime = dwLowDateTime
            self.dwHighDateTime = dwHighDateTime
        }
    }

    public struct ULARGE_INTEGER {
        var LowPart: UInt32
        var HighPart: UInt32
        var QuadPart: UInt64 {
            return UInt64(LowPart) | (UInt64(HighPart) << 32)
        }

        init() {
            LowPart = 0
            HighPart = 0
        }

        init(LowPart: UInt32, HighPart: UInt32) {
            self.LowPart = LowPart
            self.HighPart = HighPart
        }

        init(QuadPart: UInt64) {
            self.LowPart = UInt32(truncatingIfNeeded: QuadPart)
            self.HighPart = UInt32(truncatingIfNeeded: QuadPart >> 32)
        }
    }
#endif

extension Date {

    public init(fileTime ft: FILETIME) {
        var li = ULARGE_INTEGER()
        li.LowPart = ft.dwLowDateTime
        li.HighPart = ft.dwHighDateTime

        let timeIntervalBetween1601AndReferenceDate: TimeInterval = 12622780800.0
        let timeInterval =
            TimeInterval(Double(li.QuadPart) / 10_000_000.0)
            - timeIntervalBetween1601AndReferenceDate
        self.init(timeIntervalSinceReferenceDate: timeInterval)
    }

    public init(timespec ts: timespec) {
        let timeInterval = Double(ts.tv_sec) + 1.0e-9 * Double(ts.tv_nsec)

        self.init(timeIntervalSince1970: timeInterval)
    }

    public init(time t: time_t) {
        self.init(timeIntervalSince1970: TimeInterval(t))
    }

}

extension Date {
    public init(dosFileTime: UInt32) {
        let year = 1980 + Int((dosFileTime >> 25) & 0x7f)
        let month = Int((dosFileTime >> 21) & 0xf)
        let day = Int((dosFileTime >> 16) & 0x1f)
        let hour = Int((dosFileTime >> 11) & 0xf)
        let minute = Int((dosFileTime >> 5) & 0x3f)
        let second = Int((dosFileTime << 1) & 0x3f)

        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )

        self = components.date!
    }

    public var dosFileTime: UInt32 {
        let dosMinTime: UInt32 = 0x0021_0000
        let dosMaxTime: UInt32 = 0xff9f_bf7d
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: self
        )
        let year = components.year! - 1980

        if (year & ~0x7f) != 0 {
            return year > 0 ? dosMaxTime : dosMinTime
        }

        var dosTime = (year & 0x7f) << 25
        dosTime |= components.month! << 21
        dosTime |= components.day! << 16
        dosTime |= components.hour! << 11
        dosTime |= components.minute! << 5
        dosTime |= components.second! >> 1

        if dosTime > dosMaxTime {
            return dosMaxTime
        }
        if dosTime < dosMinTime {
            return dosMinTime
        }

        return UInt32(dosTime)
    }
}
