import SwiftUI

@main
struct ExampleiOSApp: App {
    init() {
        // UI テストからの診断用: 未捕捉の ObjC 例外の内容をファイルに書き出す
        if let path = ProcessInfo.processInfo.environment["LAPERM_CRASH_LOG"] {
            crashLogPath = path
            NSSetUncaughtExceptionHandler { exception in
                let text = "\(exception.name.rawValue): \(exception.reason ?? "")\n"
                    + exception.callStackSymbols.joined(separator: "\n")
                try? text.write(toFile: crashLogPath, atomically: true, encoding: .utf8)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

nonisolated(unsafe) private var crashLogPath = ""
