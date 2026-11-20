import Foundation

/// Runs `loomy publish`. build.sh writes the paths of node, the CLI, and the tools into Info.plist,
/// because an app that starts from Finder does not get the PATH of the shell.
struct LoomyCLI {
  let node: String
  let script: String
  let path: String

  static func fromBundle() -> LoomyCLI? {
    let info = Bundle.main.infoDictionary ?? [:]
    guard let node = info["LoomyNode"] as? String, let script = info["LoomyCLI"] as? String,
      let path = info["LoomyPath"] as? String, !node.isEmpty, !script.isEmpty
    else { return nil }
    return LoomyCLI(node: node, script: script, path: path)
  }

  /// The log of all publish runs: ~/Library/Logs/Loomy Recorder/publish.log.
  static var logURL: URL {
    FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Logs/Loomy Recorder/publish.log")
  }

  /// Publishes a file. `onLink` gets the link when the CLI prints it. `onExit` gets the exit code and the last lines of stderr.
  /// The CLI copies the link to the clipboard. Exit code 2 means that the link works but the transcript or the archive copy failed.
  func publish(
    file: URL,
    title: String?,
    onLink: @escaping @MainActor (String) -> Void,
    onExit: @escaping @MainActor (Int32, String) -> Void
  ) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: node)
    process.arguments = [script, "publish", file.path] + (title.map { ["--title", $0] } ?? [])
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = path
    process.environment = environment

    let log = Self.openLog()
    log?.write("\n== \(Date()) publish \(file.path)\n".data(using: .utf8)!)

    let lock = NSLock()
    var stdoutBuffer = Data()
    var stderrBuffer = Data()
    var linkSent = false

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    stdout.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      log?.write(data)
      lock.lock()
      stdoutBuffer.append(data)
      let text = String(decoding: stdoutBuffer, as: UTF8.self)
      var link: String?
      if !linkSent, let line = text.split(separator: "\n").first(where: { $0.hasPrefix("http") }) {
        linkSent = true
        link = String(line)
      }
      lock.unlock()
      if let link { Task { @MainActor in onLink(link) } }
    }
    stderr.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      log?.write(data)
      lock.lock()
      stderrBuffer.append(data)
      lock.unlock()
    }
    process.terminationHandler = { process in
      // Read the rest of the output before the report.
      stdout.fileHandleForReading.readabilityHandler = nil
      stderr.fileHandleForReading.readabilityHandler = nil
      let rest = stderr.fileHandleForReading.readDataToEndOfFile()
      log?.write(rest)
      log?.write("== exit \(process.terminationStatus)\n".data(using: .utf8)!)
      try? log?.close()
      lock.lock()
      stderrBuffer.append(rest)
      let lines = String(decoding: stderrBuffer, as: UTF8.self).split(separator: "\n").suffix(6).joined(separator: "\n")
      lock.unlock()
      let status = process.terminationStatus
      Task { @MainActor in onExit(status, lines) }
    }
    try process.run()
  }

  private static func openLog() -> FileHandle? {
    let url = logURL
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
    return handle
  }
}
