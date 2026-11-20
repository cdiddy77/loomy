import AppKit
import AVFoundation

/// The choices of the person. UserDefaults keeps them between launches.
enum Settings {
  private static let store = UserDefaults.standard

  /// When this is false, the recording has no camera bubble.
  static var cameraOn: Bool {
    get { store.object(forKey: "cameraOn") as? Bool ?? true }
    set { store.set(newValue, forKey: "cameraOn") }
  }

  /// The uniqueID of the camera. Nil means the default camera.
  static var cameraID: String? {
    get { store.string(forKey: "cameraID") }
    set { store.set(newValue, forKey: "cameraID") }
  }

  /// "none", "default", or the uniqueID of a microphone.
  static var microphone: String {
    get { store.string(forKey: "microphone") ?? "default" }
    set { store.set(newValue, forKey: "microphone") }
  }

  static var systemAudio: Bool {
    get { store.object(forKey: "systemAudio") as? Bool ?? true }
    set { store.set(newValue, forKey: "systemAudio") }
  }

  /// The display to record. Nil means the main display.
  static var displayID: CGDirectDisplayID? {
    get { (store.object(forKey: "displayID") as? NSNumber)?.uint32Value }
    set { store.set(newValue.map { NSNumber(value: $0) }, forKey: "displayID") }
  }

  /// The diameter of the camera bubble, in points.
  static var bubbleSize: CGFloat {
    get { store.object(forKey: "bubbleSize") as? CGFloat ?? 220 }
    set { store.set(newValue, forKey: "bubbleSize") }
  }

  /// The last origin of the camera bubble, in screen coordinates.
  static var bubbleOrigin: NSPoint? {
    get {
      guard let x = store.object(forKey: "bubbleX") as? CGFloat, let y = store.object(forKey: "bubbleY") as? CGFloat
      else { return nil }
      return NSPoint(x: x, y: y)
    }
    set {
      store.set(newValue?.x, forKey: "bubbleX")
      store.set(newValue?.y, forKey: "bubbleY")
    }
  }

  @MainActor static func screen() -> NSScreen {
    let screens = NSScreen.screens
    return screens.first { $0.displayID == displayID } ?? NSScreen.main ?? screens[0]
  }

  static func cameras() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
      mediaType: .video,
      position: .unspecified
    ).devices
  }

  static func microphones() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified)
      .devices
  }

  /// The folder for recordings: ~/Movies/Loomy.
  static func recordingsFolder() throws -> URL {
    let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Loomy", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
}

extension NSScreen {
  var displayID: CGDirectDisplayID {
    (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
  }
}

/// An error with a message for the person. When settingsPane is set, the alert can open that pane of System Settings.
struct LoomyError: LocalizedError {
  let message: String
  var settingsPane: String? = nil
  var errorDescription: String? { message }

  static let screenPane = "Privacy_ScreenCapture"
  static let cameraPane = "Privacy_Camera"
  static let microphonePane = "Privacy_Microphone"
}

enum Permissions {
  /// Asks for access to the camera or the microphone. Returns false when the person did not allow it.
  static func request(_ type: AVMediaType) async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: type) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
    default: return false
    }
  }

  static func requireScreen() throws {
    if CGPreflightScreenCaptureAccess() { return }
    // This shows the system prompt one time. After that, only System Settings can give the access.
    CGRequestScreenCaptureAccess()
    throw LoomyError(
      message: "Loomy Recorder cannot record the screen. In System Settings, allow Loomy Recorder in Screen & System Audio Recording. Then quit Loomy Recorder and open it again.",
      settingsPane: LoomyError.screenPane
    )
  }
}
