import AVFoundation
import ScreenCaptureKit

/// Records one display to an MP4 file with ScreenCaptureKit.
/// The recording includes the windows of other apps and the camera bubble. It does not include the other windows of this app.
@MainActor
final class Recorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
  private var stream: SCStream?
  private var output: SCRecordingOutput?
  private var url: URL?
  private var finished = false
  private var failure: Error?
  private var waiter: CheckedContinuation<Void, Never>?

  /// Called when the system stops the stream, for example when the person stops the recording from the system menu.
  var onSystemStop: ((Error) -> Void)?

  var duration: TimeInterval { output.map { CMTimeGetSeconds($0.recordedDuration) } ?? 0 }

  func start(
    display displayID: CGDirectDisplayID,
    keepWindows: [CGWindowID],
    microphone: String,
    systemAudio: Bool,
    to url: URL
  ) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
      throw LoomyError(message: "Loomy Recorder did not find the display.")
    }
    let ownApp = content.applications.filter { $0.processID == getpid() }
    let kept = content.windows.filter { keepWindows.contains($0.windowID) }
    let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: kept)

    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    config.width = Int(filter.contentRect.width * scale)
    config.height = Int(filter.contentRect.height * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.queueDepth = 6
    config.showsCursor = true
    config.showMouseClicks = true
    config.capturesAudio = systemAudio
    config.excludesCurrentProcessAudio = true
    if microphone != "none" {
      config.captureMicrophone = true
      config.microphoneCaptureDeviceID = microphone == "default" ? nil : microphone
    }

    let recording = SCRecordingOutputConfiguration()
    recording.outputURL = url
    recording.outputFileType = .mp4
    // HEVC makes a smaller original file, and it accepts displays that are wider than 4096 pixels.
    recording.videoCodecType = recording.availableVideoCodecTypes.contains(.hevc) ? .hevc : .h264
    if #available(macOS 27.0, *) {
      recording.mixesAudioWithMicrophone = true
    }

    let output = SCRecordingOutput(configuration: recording, delegate: self)
    let stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream.addRecordingOutput(output)
    finished = false
    failure = nil
    self.url = url
    self.output = output
    self.stream = stream
    try await stream.startCapture()
  }

  /// Stops the recording and returns the file.
  func stop() async throws -> URL {
    guard let stream, let url else { throw LoomyError(message: "No recording is in progress.") }
    do {
      try await stream.stopCapture()
    } catch {
      // The stream is already stopped when the system stopped it.
    }
    await waitForFinish()
    self.stream = nil
    self.output = nil
    self.url = nil
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw LoomyError(message: "The recording file does not exist. \(failure?.localizedDescription ?? "")")
    }
    return url
  }

  private func waitForFinish() async {
    if finished { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      waiter = continuation
      // Do not wait forever if the delegate does not report the end.
      DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.markFinished() }
    }
  }

  private func markFinished() {
    finished = true
    waiter?.resume()
    waiter = nil
  }

  nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
    Task { @MainActor in self.markFinished() }
  }

  nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
    Task { @MainActor in
      self.failure = error
      self.markFinished()
    }
  }

  nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
    Task { @MainActor in
      guard self.stream === stream else { return }
      self.onSystemStop?(error)
    }
  }
}
