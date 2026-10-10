//
//  DecimalAnswer.swift
//  Number Reef
//
//  Answers that land behind the decimal point, as the Percentages "Decimal"
//  button produces them.
//
//  Everything is computed in *hundredths as an integer*. No floating point
//  touches a question at any point, so 0.30 can never surface as 0.29999999,
//  and two answers are equal exactly when their hundredths are equal. Only at
//  the very last moment is the value turned into text, with the decimal
//  separator of the language the player is reading — a comma in Dutch, a point
//  in English.
//

import Foundation

public enum DecimalAnswer {
    /// Supplies the separator to print. The app points this at the in-app
    /// language switch on launch; the default follows the device.
    public nonisolated(unsafe) static var separatorProvider: () -> String = {
        Locale.current.decimalSeparator ?? "."
    }

    /// The only fractional parts a question may produce, in hundredths: the
    /// tenths, the quarters, and the rounded thirds. Anything else is noise a
    /// child cannot check by hand.
    public static let allowedFractionalParts: Set<Int> =
        Set(stride(from: 10, through: 90, by: 10)).union([25, 75]).union([33, 67])

    /// Ceiling on a decimal answer (in hundredths). Beyond this the sum stops
    /// being about the decimal and starts being about big multiplication.
    public static let maximumHundredths = 6_000

    /// Whether this value needs the decimal treatment at all.
    public static func isWhole(hundredths: Int) -> Bool { hundredths % 100 == 0 }

    /// "2,5" / "2.33" / "0,7" — trailing zeroes trimmed, whole values printed
    /// without a separator at all.
    public static func text(hundredths: Int) -> String {
        let negative = hundredths < 0
        let value = abs(hundredths)
        let whole = value / 100
        let rest = value % 100
        let sign = negative ? "-" : ""
        guard rest != 0 else { return "\(sign)\(whole)" }
        let separator = separatorProvider()
        let digits = rest % 10 == 0 ? "\(rest / 10)" : String(format: "%02d", rest)
        return "\(sign)\(whole)\(separator)\(digits)"
    }
}
