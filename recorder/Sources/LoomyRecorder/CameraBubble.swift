import AppKit
@preconcurrency import AVFoundation

/// A round window that shows the camera. The screen recording includes it.
/// The person can move it with the mouse. Settings keeps its position.
@MainActor
final class CameraBubble {
  private var panel: NSPanel?
  private var session: AVCaptureSession?
  private var moveObserver: NSObjectProtocol?
  private let queue = DispatchQueue(label: "loomy.camera")

  var windowID: CGWindowID? { panel.map { CGWindowID($0.windowNumber) } }

  func show(on screen: NSScreen, cameraID: String?, size: CGFloat) async throws {
    hide()
    guard await Permissions.request(.video) else {
      throw LoomyError(
        message: "Loomy Recorder cannot use the camera. Allow it in System Settings, or select No Camera.",
        settingsPane: LoomyError.cameraPane
      )
    }
    let device = cameraID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? AVCaptureDevice.default(for: .video)
    guard let device else { throw LoomyError(message: "Loomy Recorder did not find a camera. Select No Camera.") }

    let session = AVCaptureSession()
    session.sessionPreset = .high
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw LoomyError(message: "Loomy Recorder cannot use \(device.localizedName).") }
    session.addInput(input)

    let panel = NSPanel(
      contentRect: frame(on: screen, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isReleasedWhenClosed = false

    let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    view.wantsLayer = true
    view.layer?.cornerRadius = size / 2
    view.layer?.masksToBounds = true
    view.layer?.borderWidth = 3
    view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
    view.layer?.backgroundColor = NSColor.black.cgColor

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    if let connection = preview.connection, connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = true
    }
    view.layer?.addSublayer(preview)
    panel.contentView = view

    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification, object: panel, queue: .main
    ) { [weak panel] _ in
      MainActor.assumeIsolated {
        if let origin = panel?.frame.origin { Settings.bubbleOrigin = origin }
      }
    }

    self.session = session
    self.panel = panel
    queue.async { session.startRunning() }
    panel.orderFrontRegardless()
  }

  func hide() {
    if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
    moveObserver = nil
    panel?.orderOut(nil)
    panel = nil
    if let session { queue.async { session.stopRunning() } }
    session = nil
  }

  /// Uses the saved position when it is on the screen. Otherwise, uses the lower-left corner of the screen.
  private func frame(on screen: NSScreen, size: CGFloat) -> NSRect {
    let visible = screen.visibleFrame
    if let origin = Settings.bubbleOrigin {
      let saved = NSRect(origin: origin, size: NSSize(width: size, height: size))
      if visible.contains(saved) { return saved }
    }
    return NSRect(x: visible.minX + 40, y: visible.minY + 40, width: size, height: size)
  }
}
