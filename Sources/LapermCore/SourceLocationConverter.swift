import Foundation
import Markdown

/// swift-markdown の SourceLocation(1-based 行、UTF-8 バイト単位 1-based 桁)を
/// UTF-16 ベースの NSRange に変換する。1 文書につき 1 インスタンス生成して使う。
struct SourceLocationConverter {
    private let text: String
    /// 各行の先頭を指す String.Index(UTF-8 視点で "\n" の直後)
    private let lineStartIndices: [String.Index]
    /// 行番号(1-based)→ インライン要素の桁に加える補正(UTF-8 バイト)。
    /// cmark はインライン要素の桁を「段落の開始桁 + 行内オフセット」で計算するため、
    /// リスト項目や引用の遅延継続行(コンテナのインデントなしで続く行)では
    /// コンテナの内容インデント分だけ桁が過大報告される。誤差は行内で一定なので
    /// Text ノードの文字列を実テキストと照合して行ごとに求める(inlineColumnDeltas(for:))。
    private var inlineColumnDeltas: [Int: Int] = [:]

    init(text: String) {
        self.text = text
        var starts: [String.Index] = [text.startIndex]
        let utf8 = text.utf8
        var i = utf8.startIndex
        while i < utf8.endIndex {
            if utf8[i] == UInt8(ascii: "\n") {
                starts.append(utf8.index(after: i))
            }
            i = utf8.index(after: i)
        }
        self.lineStartIndices = starts
    }

    /// `isInline` が true のとき(インライン要素)だけ遅延継続行の桁補正を適用する。
    /// ブロック要素の桁はブロックパーサーが実際の行から求めるため正しい。
    func nsRange(of sourceRange: SourceRange, isInline: Bool = false) -> NSRange? {
        guard let lower = stringIndex(of: sourceRange.lowerBound, isInline: isInline),
              let upper = stringIndex(of: sourceRange.upperBound, isInline: isInline),
              lower <= upper else { return nil }
        return NSRange(lower..<upper, in: text)
    }

    private func stringIndex(of location: SourceLocation, isInline: Bool) -> String.Index? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count else { return nil }
        let lineStart = lineStartIndices[lineIndex]
        let utf8 = text.utf8
        let delta = isInline ? (inlineColumnDeltas[location.line] ?? 0) : 0
        let byteOffset = location.column - 1 + delta
        guard byteOffset >= 0,
              let index = utf8.index(lineStart, offsetBy: byteOffset, limitedBy: utf8.endIndex)
        else { return nil }
        // 行内桁が実際には次行へはみ出すケース(不正な column)を拒否する
        if lineIndex + 1 < lineStartIndices.count, index > lineStartIndices[lineIndex + 1] {
            return nil
        }
        return index
    }

    // MARK: - 遅延継続行の桁補正

    /// document 内の Text ノード(リテラル文字列を持つ)を実テキストと照合し、
    /// 桁がずれている行の補正量を計算して保持した新しいコンバータを返す。
    ///
    /// 10k 行級の文書でも毎回のパースで呼ばれるため、通常の行(報告位置にそのまま文字列が
    /// ある = 補正不要)は String.Index の比較だけで済ませ、配列や辞書の確保は
    /// 不一致だった行に限る。
    func applyingInlineColumnDeltas(for document: Document) -> SourceLocationConverter {
        var resolved = Set<Int>()  // 補正不要と確定した行
        var pending: [Int: [(reported: Int, needle: String)]] = [:]  // 不一致だった Text ノード
        var pendingOrder: [Int] = []
        func visit(_ markup: Markup) {
            if let node = markup as? Markdown.Text {
                guard let range = node.range,
                      range.lowerBound.line == range.upperBound.line else { return }
                let line = range.lowerBound.line
                guard !resolved.contains(line) else { return }
                let reported = range.lowerBound.column - 1
                if matches(node.string, atByteOffset: reported, ofLine: line) {
                    resolved.insert(line)
                    pending[line] = nil
                } else {
                    if pending[line] == nil { pendingOrder.append(line) }
                    pending[line, default: []].append((reported, node.string))
                }
                return
            }
            for child in markup.children { visit(child) }
        }
        visit(document)

        var deltas: [Int: Int] = [:]
        for line in pendingOrder {
            guard let nodes = pending[line], let lineBytes = utf8Bytes(ofLine: line) else { continue }
            if let delta = inlineColumnDelta(forLine: lineBytes, nodes: nodes), delta != 0 {
                deltas[line] = delta
            }
        }
        var copy = self
        copy.inlineColumnDeltas = deltas
        return copy
    }

    /// 行(1-based)の byteOffset 位置から needle の UTF-8 列がそのまま並んでいるか(配列確保なし)。
    private func matches(_ needle: String, atByteOffset byteOffset: Int, ofLine line: Int) -> Bool {
        let lineIndex = line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count, byteOffset >= 0 else { return false }
        let utf8 = text.utf8
        let lineEnd = lineIndex + 1 < lineStartIndices.count ? lineStartIndices[lineIndex + 1] : utf8.endIndex
        guard let start = utf8.index(lineStartIndices[lineIndex], offsetBy: byteOffset, limitedBy: lineEnd)
        else { return false }
        return utf8[start..<lineEnd].starts(with: needle.utf8)
    }

    /// 行(1-based)の UTF-8 バイト列(末尾の改行を含む)。範囲外なら nil。
    private func utf8Bytes(ofLine line: Int) -> [UInt8]? {
        let lineIndex = line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndices.count else { return nil }
        let start = lineStartIndices[lineIndex]
        let end = lineIndex + 1 < lineStartIndices.count ? lineStartIndices[lineIndex + 1] : text.endIndex
        return Array(text.utf8[start..<end])
    }

    /// 報告位置と一致しなかった Text ノード群(1 行ぶん)から桁補正量を求める。
    /// - 文字列が行内で見つかる最初のノードについて、報告位置に最も近い出現位置との差を
    ///   補正量とする(同距離なら手前側 = 過大報告の補正)。
    /// - 同じ行の他のノードも(行内に出現する限り)同じ補正量で一致することを確認し、
    ///   矛盾があれば補正しない。
    /// - エスケープ(`\*`)や実体参照(`&amp;`)で文字列が原文と一致しないノードは自然に除外される。
    private func inlineColumnDelta(
        forLine lineBytes: [UInt8], nodes: [(reported: Int, needle: String)]
    ) -> Int? {
        let anchors = nodes.map { (reported: $0.reported, needle: Array($0.needle.utf8)) }
            .filter { !$0.needle.isEmpty }
        for anchor in anchors {
            let occurrences = occurrencesOf(anchor.needle, in: lineBytes)
            guard !occurrences.isEmpty else { continue }
            let best = occurrences.min { lhs, rhs in
                let dl = abs(lhs - anchor.reported), dr = abs(rhs - anchor.reported)
                return dl != dr ? dl < dr : lhs < rhs
            }!
            let delta = best - anchor.reported
            let consistent = anchors.allSatisfy { other in
                occurrencesOf(other.needle, in: lineBytes).isEmpty
                    || matches(other.needle, in: lineBytes, at: other.reported + delta)
            }
            return consistent ? delta : nil
        }
        return nil
    }

    private func matches(_ needle: [UInt8], in haystack: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + needle.count <= haystack.count else { return false }
        return haystack[offset..<(offset + needle.count)].elementsEqual(needle)
    }

    private func occurrencesOf(_ needle: [UInt8], in haystack: [UInt8]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var result: [Int] = []
        for offset in 0...(haystack.count - needle.count) where matches(needle, in: haystack, at: offset) {
            result.append(offset)
        }
        return result
    }
}
