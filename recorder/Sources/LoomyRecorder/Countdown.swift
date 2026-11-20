import AppKit

/// Shows 3, 2, 1 in the center of the screen before the recording starts.
/// The recording does not include this window.
@MainActor
enum Countdown {
  static func run(on screen: NSScreen) async {
    let side: CGFloat = 180
    let frame = NSRect(x: screen.frame.midX - side / 2, y: screen.frame.midY - side / 2, width: side, height: side)
    let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.level = .screenSaver
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false

    let view = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
    view.wantsLayer = true
    view.layer?.cornerRadius = 36
    view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor

    let label = NSTextField(labelWithString: "3")
    label.font = .monospacedDigitSystemFont(ofSize: 110, weight: .bold)
    label.textColor = .white
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    panel.contentView = view
    panel.orderFrontRegardless()

    for number in [3, 2, 1] {
      label.stringValue = "\(number)"
      try? await Task.sleep(for: .milliseconds(800))
    }
    panel.orderOut(nil)
  }
}
