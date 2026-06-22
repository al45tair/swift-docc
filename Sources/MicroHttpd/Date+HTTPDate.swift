/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2026 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

#if canImport(FoundationEssentials)
    public import FoundationEssentials
#else
    public import Foundation
#endif

private func intToString<T: BinaryInteger>(
    _ value: T, width: Int
) -> String {
    let s = String(value)
    if s.count < width {
        let zeroes = String(repeating: "0", count: width - s.count)
        return zeroes + s
    }
    return s
}

// Sadly, Date.HTTPFormatStyle requires macOS 26
extension Date {
    public var httpDate: String {
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: .gmt, from: self
        )

        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = [
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
        ]

        let weekday = weekdays[components.weekday! - 1]
        let day = intToString(components.day!, width: 2)
        let month = months[components.month! - 1]
        let year = String(components.year!)
        let hour = intToString(components.hour!, width: 2)
        let minute = intToString(components.minute!, width: 2)
        let second = intToString(components.second!, width: 2)

        return "\(weekday), \(day) \(month) \(year) \(hour):\(minute):\(second) GMT"
    }
}
