import Foundation

/// NSString(UTF-16)走査で使う ASCII 定数と判定。
/// `unichar(UnicodeScalar("x").value)` の反復生成を避け、表記を 1 箇所に揃える。
enum ASCII {
    static let tab: unichar = 0x09
    static let newline: unichar = 0x0A
    static let carriageReturn: unichar = 0x0D
    static let space: unichar = 0x20
    static let hash: unichar = 0x23
    static let leftParen: unichar = 0x28
    static let rightParen: unichar = 0x29
    static let asterisk: unichar = 0x2A
    static let plus: unichar = 0x2B
    static let dash: unichar = 0x2D
    static let period: unichar = 0x2E
    static let colon: unichar = 0x3A
    static let greaterThan: unichar = 0x3E
    static let leftBracket: unichar = 0x5B
    static let backslash: unichar = 0x5C
    static let rightBracket: unichar = 0x5D
    static let backtick: unichar = 0x60
    static let pipe: unichar = 0x7C
    static let tilde: unichar = 0x7E

    static func isDigit(_ c: unichar) -> Bool {
        c >= 0x30 && c <= 0x39
    }

    static func isAlphanumeric(_ c: unichar) -> Bool {
        isDigit(c) || (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
    }
}
