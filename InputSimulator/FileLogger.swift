import Foundation

private let logPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/InputSimulator.log")
private let logQueue = DispatchQueue(label: "com.niklas.inputsimulator.filelog")
private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f
}()

func flog(_ message: String, file: String = #fileID, line: Int = #line) {
    let ts = dateFormatter.string(from: Date())
    let src = (file as NSString).lastPathComponent.replacingOccurrences(of: ".swift", with: "")
    let entry = "[\(ts)] [\(src):\(line)] \(message)\n"
    logQueue.async {
        if let data = entry.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath.path) {
                if let handle = try? FileHandle(forWritingTo: logPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logPath, options: .atomic)
            }
        }
    }
}

func fclear() {
    logQueue.async {
        try? "".write(to: logPath, atomically: true, encoding: .utf8)
    }
}
