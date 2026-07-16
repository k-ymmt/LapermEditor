// キーボード入力ソースの取得・切替(TIS API)。
// 引数なし: 現在の入力ソース ID を出力(検証前に保存しておく)
// 引数あり: その ID の入力ソースへ切替(例: com.apple.keylayout.ABC)
// 使い方: swift switch-input-source.swift [inputSourceID]
import Carbon
import Foundation

let args = CommandLine.arguments
if args.count > 1 {
    let targetID = args[1]
    let filter = [kTISPropertyInputSourceID as String: targetID] as CFDictionary
    if let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
       let src = list.first {
        TISSelectInputSource(src)
        print("selected: \(targetID)")
    } else {
        print("not found: \(targetID)")
        exit(1)
    }
} else {
    let cur = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    if let ptr = TISGetInputSourceProperty(cur, kTISPropertyInputSourceID) {
        let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        print(id)
    }
}
