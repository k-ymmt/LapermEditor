import Foundation

/// UTF-16 オフセット → 1-based 行番号の変換。編集のたびに作り直す。
/// 行の定義はガターが行情報を得るレイアウトフラグメント(= NSTextParagraph)に合わせ、
/// NSString の段落区切り("\n" / "\r" / "\r\n" / U+2029)で数える。
struct LineIndex {
    /// 各行の先頭 UTF-16 オフセット(昇順)
    private let lineStarts: [Int]

    init(text: String) {
        let ns = text as NSString
        let length = ns.length
        var starts = [0]
        // character(at:) の 1 文字ずつの呼び出し(ネイティブ String をブリッジした場合は
        // breadcrumbs 経由で特に遅い)を避け、チャンク単位で取り出して走査する
        let chunkSize = 4096
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var location = 0
        var previousWasCR = false
        while location < length {
            let count = min(chunkSize, length - location)
            buffer.withUnsafeMutableBufferPointer { pointer in
                ns.getCharacters(pointer.baseAddress!, range: NSRange(location: location, length: count))
            }
            for i in 0..<count {
                let c = buffer[i]
                let offset = location + i
                switch c {
                case 0x0A:  // LF("\r\n" の LF は行頭を 1 回だけ登録する)
                    if previousWasCR { starts[starts.count - 1] = offset + 1 } else { starts.append(offset + 1) }
                    previousWasCR = false
                case 0x0D:  // CR
                    starts.append(offset + 1)
                    previousWasCR = true
                case 0x2029:  // PARAGRAPH SEPARATOR
                    starts.append(offset + 1)
                    previousWasCR = false
                default:
                    previousWasCR = false
                }
            }
            location += count
        }
        self.lineStarts = starts
    }

    func lineNumber(at utf16Offset: Int) -> Int {
        // lineStarts[i] <= offset を満たす最大の i を二分探索
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= utf16Offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }
}
