import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
  private enum State {
    case idle
    case starting
    case recording(since: Date)
    case stopping
  }

  private var statusItem: NSStatusItem!
  private let menu = NSMenu()
  private let bubble = CameraBubble()
  private let recorder = Recorder()
  private let cli = LoomyCLI.fromBundle()
  private var state = State.idle
  private var timer: Timer?
  private var publishing: [UUID: String] = [:]
  private var lastLink: String?
  private var flash: String?
  private var flashTimer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.target = self
    statusItem.button?.action = #selector(statusItemClicked)
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    menu.delegate = self
    updateStatusItem()

    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      AppLog.write("Notification permission: \(granted)\(error.map { ", error: \($0)" } ?? "")")
    }

    recorder.onSystemStop = { [weak self] _ in self?.stopRecording(publish: true) }

    if CommandLine.arguments.contains("--self-test") {
      Task { await selfTest() }
    }
  }

  /// Records 5 seconds with the current settings, writes the result to self-test.log, and quits.
  /// Use: open "~/Applications/Loomy Recorder.app" --args --self-test
  private func selfTest() async {
    var result: String
    do {
      try Permissions.requireScreen()
      if Settings.microphone != "none" { _ = await Permissions.request(.audio) }
      let screen = Settings.screen()
      if Settings.cameraOn {
        try await bubble.show(on: screen, cameraID: Settings.cameraID, size: Settings.bubbleSize)
      }
      try await Task.sleep(for: .seconds(2))
      let url = FileManager.default.temporaryDirectory.appendingPathComponent("loomy-self-test.mp4")
      try? FileManager.default.removeItem(at: url)
      try await recorder.start(
        display: screen.displayID,
        keepWindows: bubble.windowID.map { [$0] } ?? [],
        microphone: Settings.microphone,
        systemAudio: Settings.systemAudio,
        to: url
      )
      try await Task.sleep(for: .seconds(5))
      result = "ok \(try await recorder.stop().path)"
    } catch {
      result = "error \(error.localizedDescription)"
    }
    bubble.hide()
    let log = LoomyCLI.logURL.deletingLastPathComponent().appendingPathComponent("self-test.log")
    try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? "\(Date()) \(result)\n".write(to: log, atomically: true, encoding: .utf8)
    NSApp.terminate(nil)
  }

  // MARK: The status item

  /// While a recording is in progress, a click on the status item stops it. A right-click opens the menu.
  @objc private func statusItemClicked() {
    let event = NSApp.currentEvent
    let rightClick = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
    if case .recording = state, !rightClick {
      stopRecording(publish: true)
      return
    }
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  private func updateStatusItem() {
    guard let button = statusItem.button else { return }
    let symbol: String
    var tint: NSColor?
    switch state {
    case .idle where flash != nil:
      symbol = "checkmark.circle.fill"
      tint = .systemGreen
    case .idle: symbol = publishing.isEmpty ? "record.circle" : "arrow.up.circle"
    case .starting, .stopping: symbol = "hourglass"
    case .recording:
      symbol = "stop.circle.fill"
      tint = .systemRed
    }
    var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Loomy Recorder")
    if let tint {
      image = image?.withSymbolConfiguration(.init(paletteColors: [tint]))
      image?.isTemplate = false
    } else {
      image?.isTemplate = true
    }
    button.image = image
    button.imagePosition = .imageLeading
    if case .recording(let since) = state {
      button.title = " " + Self.clock(Date().timeIntervalSince(since))
    } else if case .idle = state, let flash {
      button.title = " " + flash
    } else {
      button.title = ""
    }
  }

  /// Shows a short message next to the icon for 5 seconds. This works also when notifications are off.
  private func showFlash(_ message: String) {
    flash = message
    flashTimer?.invalidate()
    flashTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.flash = nil
        self?.updateStatusItem()
      }
    }
    updateStatusItem()
  }

  private static func clock(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    return total >= 3600
      ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
      : String(format: "%d:%02d", total / 60, total % 60)
  }

  // MARK: The menu

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    if case .recording = state {
      menu.addItem(ActionItem("Stop and Publish") { [weak self] in self?.stopRecording(publish: true) })
      menu.addItem(ActionItem("Cancel Recording") { [weak self] in self?.stopRecording(publish: false) })
      return
    }
    guard case .idle = state else {
      menu.addItem(Self.label("Wait…"))
      return
    }

    menu.addItem(ActionItem("Start Recording") { [weak self] in self?.startRecording() })
    menu.addItem(ActionItem("Upload a File…") { [weak self] in self?.uploadFile() })
    menu.addItem(.separator())

    if NSScreen.screens.count > 1 {
      let current = Settings.screen().displayID
      menu.addItem(submenu("Display", NSScreen.screens.map { screen in
        ActionItem(screen.localizedName, checked: screen.displayID == current) { Settings.displayID = screen.displayID }
      }))
    }

    var cameras: [NSMenuItem] = [
      ActionItem("No Camera", checked: !Settings.cameraOn) { Settings.cameraOn = false }
    ]
    let defaultCamera = AVCaptureDevice.default(for: .video)?.uniqueID
    for device in Settings.cameras() {
      let selected = Settings.cameraOn && device.uniqueID == (Settings.cameraID ?? defaultCamera)
      cameras.append(ActionItem(device.localizedName, checked: selected) {
        Settings.cameraOn = true
        Settings.cameraID = device.uniqueID
      })
    }
    cameras.append(.separator())
    for (name, size) in [("Small Bubble", 160.0), ("Medium Bubble", 220.0), ("Large Bubble", 320.0)] {
      cameras.append(ActionItem(name, checked: Settings.bubbleSize == size) { Settings.bubbleSize = size })
    }
    menu.addItem(submenu("Camera", cameras))

    var microphones: [NSMenuItem] = [
      ActionItem("No Microphone", checked: Settings.microphone == "none") { Settings.microphone = "none" },
      ActionItem("System Default", checked: Settings.microphone == "default") { Settings.microphone = "default" },
    ]
    for device in Settings.microphones() {
      microphones.append(ActionItem(device.localizedName, checked: Settings.microphone == device.uniqueID) {
        Settings.microphone = device.uniqueID
      })
    }
    menu.addItem(submenu("Microphone", microphones))
    menu.addItem(ActionItem("Record System Audio", checked: Settings.systemAudio) { Settings.systemAudio.toggle() })

    if !publishing.isEmpty || lastLink != nil { menu.addItem(.separator()) }
    for title in publishing.values.sorted() {
      menu.addItem(Self.label("Publish: \(title)…"))
    }
    if let lastLink {
      menu.addItem(ActionItem("Copy the Last Link") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastLink, forType: .string)
      })
      menu.addItem(ActionItem("Open the Last Link") {
        if let url = URL(string: lastLink) { NSWorkspace.shared.open(url) }
      })
    }

    menu.addItem(.separator())
    menu.addItem(ActionItem("Open the Recordings Folder") {
      if let folder = try? Settings.recordingsFolder() { NSWorkspace.shared.open(folder) }
    })
    menu.addItem(ActionItem("Open the Publish Log") {
      NSWorkspace.shared.open(LoomyCLI.logURL)
    })
    let login = SMAppService.mainApp
    menu.addItem(ActionItem("Open at Login", checked: login.status == .enabled) { [weak self] in
      do {
        if login.status == .enabled { try login.unregister() } else { try login.register() }
      } catch {
        self?.showError("Loomy Recorder cannot change the login item.", error)
      }
    })
    menu.addItem(ActionItem("Quit Loomy Recorder") { NSApp.terminate(nil) })
  }

  private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let sub = NSMenu(title: title)
    items.forEach(sub.addItem)
    item.submenu = sub
    return item
  }

  private static func label(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    return item
  }

  // MARK: Recording

  private func startRecording() {
    guard case .idle = state else { return }
    guard cli != nil else {
      showError("Loomy Recorder does not know where the loomy CLI is.", LoomyError(message: "Run recorder/build.sh again."))
      return
    }
    state = .starting
    updateStatusItem()
    Task { [weak self] in
      guard let self else { return }
      do {
        try Permissions.requireScreen()
        if Settings.microphone != "none", !(await Permissions.request(.audio)) {
          throw LoomyError(
            message: "Loomy Recorder cannot use the microphone. Allow it in System Settings, or select No Microphone.",
            settingsPane: LoomyError.microphonePane
          )
        }
        let screen = Settings.screen()
        if Settings.cameraOn {
          try await bubble.show(on: screen, cameraID: Settings.cameraID, size: Settings.bubbleSize)
        }
        // The countdown also gives the camera bubble time to appear in the list of windows.
        await Countdown.run(on: screen)
        let name = "Loomy \(Self.fileDate.string(from: Date())).mp4"
        let url = try Settings.recordingsFolder().appendingPathComponent(name)
        try await recorder.start(
          display: screen.displayID,
          keepWindows: bubble.windowID.map { [$0] } ?? [],
          microphone: Settings.microphone,
          systemAudio: Settings.systemAudio,
          to: url
        )
        state = .recording(since: Date())
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.updateStatusItem() }
        }
        updateStatusItem()
      } catch {
        bubble.hide()
        state = .idle
        updateStatusItem()
        showError("The recording did not start.", error)
      }
    }
  }

  private func stopRecording(publish: Bool) {
    guard case .recording = state else { return }
    state = .stopping
    timer?.invalidate()
    timer = nil
    updateStatusItem()
    Task {
      defer {
        state = .idle
        updateStatusItem()
      }
      do {
        let url = try await recorder.stop()
        bubble.hide()
        if publish {
          review(url, title: "Recording \(Self.titleDate.string(from: Date()))", isRecording: true)
        } else {
          _ = try? await NSWorkspace.shared.recycle([url])
        }
      } catch {
        bubble.hide()
        showError("The recording did not stop correctly.", error)
      }
    }
  }

  private static let fileDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
    return formatter
  }()

  private static let titleDate: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
  }()

  // MARK: Publish

  private func uploadFile() {
    NSApp.activate()
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .video, .audiovisualContent]
    panel.allowsMultipleSelection = false
    panel.message = "Select a video to publish."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    review(url, title: url.deletingPathExtension().lastPathComponent, isRecording: false)
  }

  /// Asks for the title. A recording can also stay on the Mac only, or go to the Trash.
  private func review(_ url: URL, title: String, isRecording: Bool) {
    NSApp.activate()
    let alert = NSAlert()
    alert.messageText = isRecording ? "Publish the recording?" : "Publish the video?"
    alert.informativeText = "Type a title. When the link is ready, Loomy copies it to the clipboard."
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
    field.stringValue = title
    alert.accessoryView = field
    alert.addButton(withTitle: "Publish")
    if isRecording {
      alert.addButton(withTitle: "Keep on This Mac")
      let trash = alert.addButton(withTitle: "Move to Trash")
      trash.hasDestructiveAction = true
    } else {
      alert.addButton(withTitle: "Cancel")
    }
    alert.window.initialFirstResponder = field

    switch alert.runModal() {
    case .alertFirstButtonReturn:
      let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      publish(url, title: typed.isEmpty ? title : typed)
    case .alertSecondButtonReturn:
      if isRecording { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    default:
      if isRecording { Task { _ = try? await NSWorkspace.shared.recycle([url]) } }
    }
  }

  private func publish(_ url: URL, title: String) {
    guard let cli else { return }
    let job = UUID()
    publishing[job] = title
    updateStatusItem()
    do {
      try cli.publish(
        file: url,
        title: title,
        onLink: { [weak self] link in
          self?.lastLink = link
          self?.showFlash("Link copied")
          NSSound(named: "Glass")?.play()
          self?.notify("The link is on the clipboard.", body: "\(title)\n\(link)", link: link)
        },
        onExit: { [weak self] status, stderr in
          guard let self else { return }
          self.publishing[job] = nil
          self.updateStatusItem()
          switch status {
          case 0: break
          case 2: self.notify("The link works, but a later step failed.", body: stderr, link: nil)
          default: self.showError("The publish of “\(title)” failed.", LoomyError(message: stderr))
          }
        }
      )
    } catch {
      publishing[job] = nil
      updateStatusItem()
      showError("The publish of “\(title)” did not start.", error)
    }
  }

  // MARK: Messages

  private func notify(_ title: String, body: String, link: String?) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    if let link { content.userInfo = ["link": link] }
    let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    UNUserNotificationCenter.current().add(request) { error in
      if let error { AppLog.write("The notification failed: \(error)") }
    }
  }

  private func showError(_ title: String, _ error: Error) {
    NSApp.activate()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    let pane = (error as? LoomyError)?.settingsPane
    if pane != nil { alert.addButton(withTitle: "Open System Settings") }
    alert.addButton(withTitle: "OK")
    if alert.runModal() == .alertFirstButtonReturn, let pane,
      let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    {
      NSWorkspace.shared.open(url)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .sound]
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    if let link = response.notification.request.content.userInfo["link"] as? String, let url = URL(string: link) {
      _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }
  }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
  private let handler: () -> Void

  init(_ title: String, checked: Bool = false, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(run), keyEquivalent: "")
    target = self
    state = checked ? .on : .off
  }

  required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

  @objc private func run() { handler() }
}
