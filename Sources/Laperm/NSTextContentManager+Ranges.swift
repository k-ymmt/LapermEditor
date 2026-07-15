import AppKit

extension NSTextContentManager {
    /// UTF-16 NSRange を NSTextRange に変換する。範囲外なら nil。
    func textRange(for range: NSRange) -> NSTextRange? {
        guard let start = location(documentRange.location, offsetBy: range.location),
              let end = location(start, offsetBy: range.length)
        else { return nil }
        return NSTextRange(location: start, end: end)
    }
}
