// Octo: Clawd as a desktop pet for Claude Code, in the spirit of ChatGPT/Codex Pets.
//
// The octo-pet mod (hooks/register.ts) writes one JSON file per Claude Code
// session into ~/.claude/octo-pet/sessions. This app floats above every window,
// shows the loudest session in a bubble and animates Clawd with frames it pulls
// from the Claude desktop app's own animation on first launch.
// Click → that session. Click the bubble → activity list. Right-click → Quick
// chat, Stop, Tuck away. Drag anywhere. Click it seven times fast for a surprise.
import AppKit
import AVFoundation

let fm = FileManager.default
let root = fm.homeDirectoryForCurrentUser.path + "/.claude/octo-pet"
let sessionsDir = root + "/sessions", cmdDir = root + "/cmd", framesDir = root + "/frames"
let pidFile = root + "/pet.pid", logFile = root + "/pet.log", eggFile = root + "/egg.png"
let claudeBundle = "com.anthropic.claudefordesktop"
// ChatGPT's order: needs input → blocked → ready → running.
let priority = ["needs-input": 0, "blocked": 1, "ready": 2, "running": 3, "idle": 4]
let labels = ["running": "Running", "needs-input": "Needs input", "ready": "Ready", "blocked": "Blocked"]
let icons = ["running": "●", "needs-input": "⏱", "ready": "✓", "blocked": "✕"]
let colors: [String: NSColor] = ["running": .systemBlue, "needs-input": .systemOrange, "ready": .systemGreen, "blocked": .systemRed]

struct Session: Decodable, Equatable {
  var id: String, desktopId: String?, title: String, state: String, detail: String, turnId: String?, updatedAt: Double, since: Double
}

func now() -> Double { Date().timeIntervalSince1970 * 1000 }

func log(_ s: String) {
  let line = "\(Date()) \(s)\n"
  if let h = FileHandle(forWritingAtPath: logFile) { h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile() }
  else { try? line.write(toFile: logFile, atomically: true, encoding: .utf8) }
}

/// Clawd's frames: the Claude desktop app ships its mascot animation as HEVC with
/// alpha. Once, we decode it, crop to the sprite, scale for retina and cache PNGs.
enum Frames {
  static let sources = ["/Applications", fm.homeDirectoryForCurrentUser.path + "/Applications"]
    .map { $0 + "/Claude.app/Contents/Resources/ion-dist/images/install-hub/clawd-laptop.mov" }

  static func load() -> [NSImage] {
    func cached() -> [NSImage] {
      ((try? fm.contentsOfDirectory(atPath: framesDir)) ?? []).filter { $0.hasSuffix(".png") }.sorted()
        .compactMap { NSImage(contentsOfFile: framesDir + "/" + $0) }
    }
    let have = cached()
    if have.count >= 24 { return have }
    do { try extract() } catch { log("frames: \(error.localizedDescription)") }
    return cached()
  }

  static func extract() throws {
    guard let src = sources.first(where: { fm.fileExists(atPath: $0) }) else {
      throw NSError(domain: "octo", code: 1, userInfo: [NSLocalizedDescriptionKey: "Claude desktop app not found; it provides Clawd's animation"])
    }
    let asset = AVURLAsset(url: URL(fileURLWithPath: src))
    guard let track = asset.tracks(withMediaType: .video).first else {
      throw NSError(domain: "octo", code: 2, userInfo: [NSLocalizedDescriptionKey: "no video track in \(src)"])
    }
    let fps = Double(track.nominalFrameRate)
    let count = Int((asset.duration.seconds * fps).rounded())
    let gen = AVAssetImageGenerator(asset: asset)
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    var images: [CGImage] = []
    for i in 0..<count {
      images.append(try gen.copyCGImage(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600), actualTime: nil))
    }
    let box = images.reduce(CGRect.null) { $0.union(opaqueBounds($1)) }
    guard !box.isNull else { throw NSError(domain: "octo", code: 3, userInfo: [NSLocalizedDescriptionKey: "animation is fully transparent"]) }
    try fm.createDirectory(atPath: framesDir, withIntermediateDirectories: true)
    let w = 320, h = Int(320 * box.height / box.width)
    for (i, img) in images.enumerated() {
      guard let cropped = img.cropping(to: box),
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
      ctx.interpolationQuality = .high
      ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
      guard let out = ctx.makeImage() else { continue }
      try NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: String(format: "%@/f%03d.png", framesDir, i + 1)))
    }
    log("frames: extracted \(count) from \(src), sprite box \(box)")
  }

  /// Bounding box of the pixels that are not fully transparent, sampled on a 4px grid.
  static func opaqueBounds(_ img: CGImage) -> CGRect {
    let full = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    guard img.bitsPerPixel == 32, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return full }
    let bpr = img.bytesPerRow
    var minX = img.width, minY = img.height, maxX = -1, maxY = -1
    var y = 0
    while y < img.height {
      var x = 0
      while x < img.width {
        let o = y * bpr + x * 4
        if p[o] | p[o + 1] | p[o + 2] | p[o + 3] != 0 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
        x += 4
      }
      y += 4
    }
    guard maxX >= 0 else { return .null }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).insetBy(dx: -6, dy: -6).intersection(full)
  }
}

final class PetWindow: NSWindow { override var canBecomeKey: Bool { true } }

/// The whole window: drag anywhere, click, right-click. Only the quick-chat field keeps its own clicks.
final class PetView: NSView {
  var onClick: ((NSPoint) -> Void)?
  var onMenu: ((NSPoint) -> Void)?
  var onPress: ((Bool) -> Void)?
  var passThrough: NSView?
  private var startMouse = NSPoint.zero, startOrigin = NSPoint.zero, moved = false

  /// A click counts even while another app is in front; AppKit would otherwise eat it as "activate".
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    super.updateTrackingAreas()
  }
  override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
  override func hitTest(_ p: NSPoint) -> NSView? {
    guard bounds.contains(p) else { return nil }
    if let f = passThrough, !f.isHidden, f.frame.contains(p) { return f.hitTest(p) }
    return self
  }
  override func mouseDown(with e: NSEvent) {
    startMouse = NSEvent.mouseLocation; startOrigin = window!.frame.origin; moved = false
    onPress?(true)
  }
  override func mouseDragged(with e: NSEvent) {
    let m = NSEvent.mouseLocation
    if !moved && hypot(m.x - startMouse.x, m.y - startMouse.y) < 5 { return }
    if !moved { moved = true; onPress?(false) }
    window!.setFrameOrigin(NSPoint(x: startOrigin.x + m.x - startMouse.x, y: startOrigin.y + m.y - startMouse.y))
  }
  override func mouseUp(with e: NSEvent) {
    onPress?(false)
    if moved { UserDefaults.standard.set(NSStringFromPoint(window!.frame.origin), forKey: "origin") }
    else { onClick?(convert(e.locationInWindow, from: nil)) }
  }
  override func rightMouseDown(with e: NSEvent) { onMenu?(convert(e.locationInWindow, from: nil)) }
}

final class App: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
  let W: CGFloat = 250, H: CGFloat = 176
  let petFrame = NSRect(x: 45, y: 36, width: 160, height: 108)
  var window: PetWindow!
  let view = PetView(), pet = NSImageView(), bubble = NSTextField(labelWithString: ""), input = NSTextField()
  var frames: [NSImage] = []
  var sessions: [Session] = []          // live, loudest first
  var seen: [String: Double] = [:]      // ready sessions the person already opened, by `since`
  var clicks: [TimeInterval] = []
  var tick = 0, lastFrame = -1, quiet = 0
  var previousApp: NSRunningApplication?
  var fireworks: NSWindow?

  var top: Session? { sessions.first }
  var state: String { top?.state ?? "idle" }

  func applicationDidFinishLaunching(_ n: Notification) {
    frames = Frames.load()
    guard frames.count >= 24 else { log("no frames: install the Claude desktop app, then run /pet"); exit(1) }

    let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    var origin = NSPoint(x: screen.maxX - W - 16, y: screen.minY + 16)
    if let s = UserDefaults.standard.string(forKey: "origin") { origin = NSPointFromString(s) }
    window = PetWindow(contentRect: NSRect(origin: origin, size: NSSize(width: W, height: H)), styleMask: [.borderless], backing: .buffered, defer: false)
    window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
    // Set explicitly: a clear window otherwise lets clicks on transparent pixels
    // (the gaps in a pixel-art sprite) fall through to whatever is behind it.
    window.ignoresMouseEvents = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isReleasedWhenClosed = false
    view.wantsLayer = true
    window.contentView = view

    pet.imageScaling = .scaleProportionallyUpOrDown
    pet.frame = petFrame
    view.addSubview(pet)

    bubble.font = .systemFont(ofSize: 12, weight: .semibold)
    bubble.textColor = .white; bubble.alignment = .center
    bubble.lineBreakMode = .byTruncatingTail; bubble.maximumNumberOfLines = 1
    bubble.cell?.usesSingleLineMode = true
    bubble.wantsLayer = true; bubble.layer?.cornerRadius = 12; bubble.layer?.masksToBounds = true
    bubble.isHidden = true
    view.addSubview(bubble)

    input.placeholderString = "Ask Claude…"
    input.font = .systemFont(ofSize: 13)
    input.frame = NSRect(x: 8, y: 4, width: W - 16, height: 26)
    input.isHidden = true
    input.delegate = self; input.target = self; input.action = #selector(submitQuickChat)
    view.addSubview(input)
    view.passThrough = input

    view.onPress = { [unowned self] down in pet.frame.origin.y = petFrame.minY - (down ? 4 : 0) }
    view.onClick = { [unowned self] p in
      if !bubble.isHidden && bubble.frame.contains(p) { showMenu(at: p); return }
      hop()
      if countClick() { firework() } else { open(top) }
    }
    view.onMenu = { [unowned self] p in showMenu(at: p) }

    window.orderFrontRegardless()
    Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [unowned self] _ in tick += 1; render() }
    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [unowned self] _ in poll() }
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [unowned self] _ in liveness() }
    poll(); render()
    log("started pid \(getpid())")
  }

  // MARK: sessions

  func poll() {
    var list: [Session] = []
    for f in (try? fm.contentsOfDirectory(atPath: sessionsDir)) ?? [] where f.hasSuffix(".json") {
      let path = sessionsDir + "/" + f
      guard let d = fm.contents(atPath: path), var s = try? JSONDecoder().decode(Session.self, from: d) else { continue }
      if s.state == "gone" || now() - s.updatedAt > 20_000 { try? fm.removeItem(atPath: path); continue }
      if s.state == "ready", let t = seen[s.id], t >= s.since { s.state = "idle" }
      list.append(s)
    }
    list.sort { (priority[$0.state] ?? 9, -$0.since) < (priority[$1.state] ?? 9, -$1.since) }
    // The only session finished while Claude is in front: the person is looking at it.
    if list.count == 1, list[0].state == "ready", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundle {
      seen[list[0].id] = list[0].since
      list[0].state = "idle"
    }
    debugRequests()
    guard list != sessions else { return }
    sessions = list
    refreshBubble()
  }

  func refreshBubble() {
    guard let s = top, let label = labels[s.state] else { bubble.isHidden = true; return }
    let others = sessions.filter { $0.state != "idle" }.count - 1
    bubble.stringValue = "\(icons[s.state] ?? "") \(label) · \(s.detail.isEmpty ? s.title : s.detail)" + (others > 0 ? "  +\(others)" : "")
    bubble.layer?.backgroundColor = colors[s.state]?.withAlphaComponent(0.92).cgColor
    bubble.isHidden = false
    bubble.sizeToFit()
    let w = min(W, bubble.frame.width + 24)
    bubble.frame = NSRect(x: (W - w) / 2, y: H - 28, width: w, height: 24)
  }

  /// Frame ranges of the clawd-laptop animation: 0–5 look around, 6 eyes shut,
  /// 15 hop, 18–35 typing on the laptop, 39–42 standing.
  func render() {
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    let n = frames.count
    let i: Int
    switch state {
    case "running": i = still ? 18 : 18 + tick % 18
    case "needs-input": i = still ? 15 : (tick / 3 % 2 == 0 ? 0 : 15)
    case "ready": i = still ? 0 : 39 + tick / 4 % 4
    case "blocked": i = 6
    default: let p = tick % 96; i = (still || p >= 18) ? 0 : p / 3
    }
    let j = min(i, n - 1)
    if j != lastFrame { lastFrame = j; pet.image = frames[j] }
  }

  // MARK: actions

  func hop() {
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.09
      pet.animator().frame.origin.y = petFrame.minY + 10
    }, completionHandler: { [unowned self] in
      NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; pet.animator().frame.origin.y = petFrame.minY }
    })
  }

  /// Seven clicks, each within 2.5s of the last.
  func countClick() -> Bool {
    let t = Date().timeIntervalSince1970
    clicks = clicks.filter { t - $0 < 2.5 } + [t]
    guard clicks.count >= 7 else { return false }
    clicks = []
    return true
  }

  func open(_ s: Session?) {
    var url = "claude://code"
    if let s, let d = s.desktopId {
      url = s.state == "needs-input" ? "claude://code/needs-input?session=\(d)" : "claude://code/continue?session=\(d)"
    }
    if let s, s.state == "ready" { seen[s.id] = s.since; poll() }
    NSWorkspace.shared.open(URL(string: url)!)
  }

  func showMenu(at p: NSPoint) {
    let menu = NSMenu()
    for s in sessions {
      let item = NSMenuItem(title: "\(labels[s.state] ?? "Idle") · \(s.title)" + (s.detail.isEmpty ? "" : " — \(s.detail)"), action: #selector(openFromMenu(_:)), keyEquivalent: "")
      item.target = self; item.representedObject = s.id
      menu.addItem(item)
    }
    if sessions.isEmpty { menu.addItem(withTitle: "No live Claude Code sessions", action: nil, keyEquivalent: "") }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quick chat…", action: #selector(showQuickChat), keyEquivalent: "").target = self
    for s in sessions where s.turnId != nil {
      let stop = menu.addItem(withTitle: "Stop · \(s.title)", action: #selector(stopFromMenu(_:)), keyEquivalent: "")
      stop.target = self; stop.representedObject = s.id
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Tuck away  (/pet wakes it)", action: #selector(tuckAway), keyEquivalent: "").target = self
    menu.popUp(positioning: nil, at: p, in: view)
  }

  @objc func openFromMenu(_ item: NSMenuItem) { open(sessions.first { $0.id == item.representedObject as? String }) }
  @objc func stopFromMenu(_ item: NSMenuItem) { if let id = item.representedObject as? String { send(["abort": true], to: id) } }

  /// Leaves a marker so sessions stop relaunching the pet until `/pet`.
  @objc func tuckAway() {
    fm.createFile(atPath: root + "/hidden", contents: nil)
    NSApp.terminate(nil)
  }

  @objc func showQuickChat() {
    previousApp = NSWorkspace.shared.frontmostApplication
    input.isHidden = false
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(input)
  }

  @objc func submitQuickChat() {
    let text = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !text.isEmpty {
      if let s = sessions.first(where: { $0.state != "blocked" }) ?? top { send(["prompt": text], to: s.id) } else { NSSound.beep() }
    }
    dismissQuickChat()
  }

  func dismissQuickChat() {
    input.stringValue = ""; input.isHidden = true
    window.makeFirstResponder(nil)
    previousApp?.activate()
  }

  func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
    if sel == #selector(NSResponder.cancelOperation(_:)) { dismissQuickChat(); return true }
    return false
  }

  /// The mod of that session polls ~/.claude/octo-pet/cmd and acts on these.
  func send(_ cmd: [String: Any], to id: String) {
    var body = cmd; body["session"] = id
    fm.createFile(atPath: "\(cmdDir)/\(id)-\(Int(now())).json", contents: try? JSONSerialization.data(withJSONObject: body))
  }

  /// Stay while Claude is open or any session is alive; otherwise leave after 30s.
  func liveness() {
    let claudeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundle).isEmpty
    quiet = sessions.isEmpty && !claudeRunning ? quiet + 1 : 0
    if quiet >= 6 { NSApp.terminate(nil) }
  }

  func applicationWillTerminate(_ n: Notification) { try? fm.removeItem(atPath: pidFile) }

  // MARK: the easter egg

  /// A burst of sparks and a familiar face, over the pet, gone in two seconds.
  func firework() {
    NSSound(named: "Pop")?.play()
    let size: CGFloat = 480
    let c = NSPoint(x: window.frame.midX, y: window.frame.midY + 40)
    let w = NSWindow(contentRect: NSRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size), styleMask: [.borderless], backing: .buffered, defer: false)
    w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
    w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    w.isReleasedWhenClosed = false
    let v = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size)); v.wantsLayer = true
    w.contentView = v
    fireworks?.orderOut(nil); fireworks = w
    w.orderFrontRegardless()

    let sparks = CAEmitterLayer()
    sparks.frame = v.bounds
    sparks.emitterPosition = CGPoint(x: size / 2, y: size / 2); sparks.emitterShape = .point; sparks.renderMode = .additive
    let cell = CAEmitterCell()
    cell.contents = sparkImage(); cell.birthRate = 500; cell.lifetime = 1.5; cell.lifetimeRange = 0.4
    cell.velocity = 340; cell.velocityRange = 180; cell.emissionRange = .pi * 2
    cell.yAcceleration = -520; cell.scale = 0.6; cell.scaleSpeed = -0.35; cell.alphaSpeed = -0.65; cell.spin = 4
    cell.color = NSColor.white.cgColor; cell.redRange = 1; cell.greenRange = 1; cell.blueRange = 1
    sparks.emitterCells = [cell]
    sparks.beginTime = CACurrentMediaTime()
    v.layer?.addSublayer(sparks)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { sparks.birthRate = 0 }

    let d: CGFloat = 200
    let face = CALayer()
    face.frame = CGRect(x: (size - d) / 2, y: (size - d) / 2, width: d, height: d)
    face.contents = (NSImage(contentsOfFile: eggFile) ?? frames[0]).cgImage(forProposedRect: nil, context: nil, hints: nil)
    face.contentsGravity = .resizeAspectFill; face.cornerRadius = d / 2; face.masksToBounds = true
    face.borderColor = NSColor.white.cgColor; face.borderWidth = 5
    v.layer?.addSublayer(face)
    let pop = CAKeyframeAnimation(keyPath: "transform.scale")
    pop.values = [0.05, 1.2, 0.95, 1.0]; pop.keyTimes = [0, 0.5, 0.8, 1]; pop.duration = 0.6
    pop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
    face.add(pop, forKey: "pop")
    let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
    let grow = CABasicAnimation(keyPath: "transform.scale"); grow.fromValue = 1; grow.toValue = 1.4
    let out = CAAnimationGroup()
    out.animations = [fade, grow]; out.beginTime = CACurrentMediaTime() + 1.7; out.duration = 0.45
    out.fillMode = .forwards; out.isRemovedOnCompletion = false
    face.add(out, forKey: "out")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) { [weak self] in
      if self?.fireworks === w { w.orderOut(nil); self?.fireworks = nil }
    }
  }

  func sparkImage() -> CGImage? {
    let s = 12
    guard let ctx = CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: s, height: s))
    return ctx.makeImage()
  }

  // MARK: debug hooks

  /// `touch ~/.claude/octo-pet/snapshot.req` → snapshot.png of the pet;
  /// `touch ~/.claude/octo-pet/egg.req` → fires the easter egg and snapshots it.
  func debugRequests() {
    if fm.fileExists(atPath: root + "/snapshot.req") {
      try? fm.removeItem(atPath: root + "/snapshot.req")
      snapshot(view, to: root + "/snapshot.png")
    }
    if fm.fileExists(atPath: root + "/egg.req") {
      try? fm.removeItem(atPath: root + "/egg.req")
      firework()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
        if let v = self?.fireworks?.contentView { self?.snapshot(v, to: root + "/snapshot-egg.png") }
      }
    }
  }

  func snapshot(_ v: NSView, to path: String) {
    let scale = v.window?.screen?.backingScaleFactor ?? 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * scale), pixelsHigh: Int(v.bounds.height * scale), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
    ctx.cgContext.scaleBy(x: scale, y: scale)
    v.layer?.presentation()?.render(in: ctx.cgContext)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}

for d in [sessionsDir, cmdDir] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
// One pet per machine: every session's mod may launch it; the extras leave.
if let s = try? String(contentsOfFile: pidFile, encoding: .utf8),
   let pid = pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)), pid != getpid(), kill(pid, 0) == 0 { exit(0) }
try? "\(getpid())".write(toFile: pidFile, atomically: true, encoding: .utf8)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = App()
app.delegate = delegate
app.run()
