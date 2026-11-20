import Foundation

/// Writes lines to ~/Library/Logs/Loomy Recorder/app.log.
enum AppLog {
  static func write(_ message: String) {
    let url = LoomyCLI.logURL.deletingLastPathComponent().appendingPathComponent("app.log")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    _ = try? handle.seekToEnd()
    handle.write("\(Date()) \(message)\n".data(using: .utf8)!)
    try? handle.close()
  }
}
