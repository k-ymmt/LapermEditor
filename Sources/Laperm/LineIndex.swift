import Foundation

/// UTF-16 オフセット → 1-based 行番号の変換。編集のたびに作り直す
/// (10k 行でも数ミリ秒。ボトルネックになったら差分更新に切り替える)。
struct LineIndex {
    /// 各行の先頭 UTF-16 オフセット(昇順)
    private let lineStarts: [Int]

    init(text: String) {
        let ns = text as NSString
        var starts = [0]
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == 10 {  // "\n"
                starts.append(i + 1)
            }
            i += 1
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
