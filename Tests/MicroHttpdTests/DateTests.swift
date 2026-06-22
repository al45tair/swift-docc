import Foundation
import Testing

@testable import MicroHttpd

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

@Test func testHttpDateFormatting() {
    let date = Date(timeIntervalSinceReferenceDate: 803381986.62762403)
    let formattedDate = date.httpDate

    #expect(formattedDate == "Wed, 17 Jun 2026 09:39:46 GMT")
}

@Test func testFILETIMEConversion() {
    let time = FILETIME(
        dwLowDateTime: 0xfbd5_82f9,
        dwHighDateTime: 0x1dcfe3f)
    let date = Date(fileTime: time)

    #expect(date.httpDate == "Wed, 17 Jun 2026 09:59:27 GMT")
    #expect(date.timeIntervalSinceReferenceDate == 803383167.5740929)
}

@Test func testTimespecConversion() {
    let ts = timespec(
        tv_sec: 1_781_691_026,
        tv_nsec: 400_763_000)
    let date = Date(timespec: ts)

    #expect(date.timeIntervalSinceReferenceDate == 803383826.400763)
}
