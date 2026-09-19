#if canImport(AppKit)
import AppKit

/// テーマ等の公開 API で使うプラットフォーム共通のフォント型(macOS: NSFont / iOS: UIFont)。
public typealias PlatformFont = NSFont
/// テーマ等の公開 API で使うプラットフォーム共通の色型(macOS: NSColor / iOS: UIColor)。
public typealias PlatformColor = NSColor
/// 画像プレビューで使うプラットフォーム共通の画像型(macOS: NSImage / iOS: UIImage)。
public typealias PlatformImage = NSImage
#elseif canImport(UIKit)
import UIKit

/// テーマ等の公開 API で使うプラットフォーム共通のフォント型(macOS: NSFont / iOS: UIFont)。
public typealias PlatformFont = UIFont
/// テーマ等の公開 API で使うプラットフォーム共通の色型(macOS: NSColor / iOS: UIColor)。
public typealias PlatformColor = UIColor
/// 画像プレビューで使うプラットフォーム共通の画像型(macOS: NSImage / iOS: UIImage)。
public typealias PlatformImage = UIImage
#endif

/// セマンティックカラーの両 OS 対応。名前が AppKit / UIKit で異なるものだけをまとめる。
extension PlatformColor {
    #if canImport(AppKit)
    static var lapermLabel: PlatformColor { .textColor }
    static var lapermSecondaryLabel: PlatformColor { .secondaryLabelColor }
    static var lapermTertiaryLabel: PlatformColor { .tertiaryLabelColor }
    static var lapermTextBackground: PlatformColor { .textBackgroundColor }
    static var lapermSeparator: PlatformColor { .separatorColor }
    static var lapermLink: PlatformColor { .linkColor }
    #else
    static var lapermLabel: PlatformColor { .label }
    static var lapermSecondaryLabel: PlatformColor { .secondaryLabel }
    static var lapermTertiaryLabel: PlatformColor { .tertiaryLabel }
    static var lapermTextBackground: PlatformColor { .systemBackground }
    static var lapermSeparator: PlatformColor { .separator }
    static var lapermLink: PlatformColor { .link }
    #endif
}

extension PlatformFont {
    /// イタリック体に変換する。変換できない場合は自身を返す。
    func lapermItalic() -> PlatformFont {
        #if canImport(AppKit)
        return NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
        #else
        guard let descriptor = fontDescriptor.withSymbolicTraits(
            fontDescriptor.symbolicTraits.union(.traitItalic))
        else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
        #endif
    }
}

#if canImport(AppKit)
/// NSTextStorageDelegate の編集種別。Swift オーバーレイでの型名が AppKit / UIKit で異なる。
typealias TextStorageEditActions = NSTextStorageEditActions
#else
typealias TextStorageEditActions = NSTextStorage.EditActions
#endif
