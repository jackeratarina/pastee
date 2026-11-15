import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

/// Hosts Flutter plus Pastee's small native bridge (channel "pastee/native"):
/// a system-wide summon shortcut, showing/hiding the app, and copying secrets.
class MainFlutterWindow: NSWindow {
  private var nativeChannel: FlutterMethodChannel?
  private let summonHotKey = GlobalHotKey()
  private let secretClipboard = SecretClipboard()

  /// How long a shortcut hide waits for Dart to call hideWindow before hiding
  /// anyway.
  private static let hideFallbackDelay: TimeInterval = 0.5
  /// Set while a shortcut hide is waiting for Dart (see toggleFromHotKey).
  private var hideFallbackTimer: Timer?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // A compact window suits a summon-and-copy tool; the layout works down to
    // the minimum size.
    self.contentMinSize = NSSize(width: 420, height: 440)
    self.setContentSize(NSSize(width: 560, height: 720))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    let channel = FlutterMethodChannel(
      name: "pastee/native", binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    nativeChannel = channel
    summonHotKey.onPressed = { [weak self] in self?.toggleFromHotKey() }

    super.awakeFromNib()
  }

  /// The close button and ⌘W hide Pastee instead of quitting, so the summon
  /// shortcut keeps working. ⌘Q still quits.
  override func performClose(_ sender: Any?) {
    hideApp()
  }

  private var isFrontmost: Bool {
    return NSApp.isActive && !NSApp.isHidden && self.isVisible && self.isKeyWindow
  }

  /// When the shortcut hides Pastee, Dart first draws its lock or privacy
  /// cover, so the system's snapshots of the window (Dock, Exposé) don't show
  /// the list, and then calls hideWindow. If it hasn't within
  /// hideFallbackDelay, Pastee hides anyway so the shortcut never feels broken.
  private func toggleFromHotKey() {
    if hideFallbackTimer != nil {
      // Pressed again while waiting for Dart: hide right away.
      hideApp()
      return
    }
    let show = !isFrontmost
    if show {
      showApp()
    } else {
      startHideFallback()
    }
    nativeChannel?.invokeMethod("onHotKey", arguments: ["shown": show])
  }

  private func startHideFallback() {
    cancelHideFallback()
    let timer = Timer(
      timeInterval: MainFlutterWindow.hideFallbackDelay, target: self,
      selector: #selector(hideFallbackFired(_:)), userInfo: nil, repeats: false)
    // The common modes keep it firing during menu tracking and live resize.
    RunLoop.main.add(timer, forMode: .common)
    hideFallbackTimer = timer
  }

  private func cancelHideFallback() {
    hideFallbackTimer?.invalidate()
    hideFallbackTimer = nil
  }

  @objc private func hideFallbackFired(_ timer: Timer) {
    hideApp()
  }

  private func showApp() {
    cancelHideFallback()
    NSApp.unhide(nil)
    if self.isMiniaturized {
      self.deminiaturize(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    self.makeKeyAndOrderFront(nil)
  }

  /// Hiding the whole app (rather than ordering the window out) hands focus
  /// back to the app you were in, so the next ⌘V lands there.
  private func hideApp() {
    cancelHideFallback()
    NSApp.hide(nil)
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "registerHotKey":
      guard let args = call.arguments as? [String: Any],
        let rawKeyCode = args["keyCode"] as? Int, let keyCode = UInt32(exactly: rawKeyCode),
        let rawModifiers = args["modifiers"] as? Int,
        let modifiers = UInt32(exactly: rawModifiers)
      else {
        result(
          FlutterError(
            code: "bad_args", message: "keyCode and modifiers are required", details: nil))
        return
      }
      let status = summonHotKey.register(keyCode: keyCode, modifiers: modifiers)
      result(Int(status))
    case "unregisterHotKey":
      summonHotKey.unregister()
      result(nil)
    case "showWindow":
      showApp()
      result(nil)
    case "hideWindow":
      hideApp()
      result(nil)
    case "isWindowActive":
      result(isFrontmost)
    case "writeClipboard":
      guard let args = call.arguments as? [String: Any], let text = args["text"] as? String
      else {
        result(FlutterError(code: "bad_args", message: "text is required", details: nil))
        return
      }
      let concealed = args["concealed"] as? Bool ?? false
      let clearOnExit = args["clearOnExit"] as? Bool ?? false
      result(secretClipboard.write(text, concealed: concealed, clearOnExit: clearOnExit))
    case "clearClipboard":
      guard let args = call.arguments as? [String: Any],
        let changeCount = args["changeCount"] as? Int
      else {
        result(FlutterError(code: "bad_args", message: "changeCount is required", details: nil))
        return
      }
      result(secretClipboard.clear(ifChangeCount: changeCount))
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// Copies text the way password managers do, and clears it again on request.
final class SecretClipboard {
  /// The nspasteboard.org marker for "a password: don't record or show it",
  /// which clipboard managers that follow the convention (Maccy, for one)
  /// skip.
  private static let concealedType = NSPasteboard.PasteboardType(
    "org.nspasteboard.ConcealedType")

  /// The change count of a secret to clear when Pastee quits, if the
  /// clipboard still holds it then.
  private var clearOnExitChangeCount: Int?
  private var terminateObserver: NSObjectProtocol?

  init() {
    terminateObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self, let changeCount = self.clearOnExitChangeCount else { return }
      _ = self.clear(ifChangeCount: changeCount)
    }
  }

  deinit {
    if let observer = terminateObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Returns the pasteboard's change count after writing.
  func write(_ text: String, concealed: Bool, clearOnExit: Bool) -> Int {
    let pasteboard = NSPasteboard.general
    if concealed {
      // currentHostOnly keeps it off Universal Clipboard, so it isn't sent
      // to the user's other Apple devices.
      _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
      _ = pasteboard.setString(text, forType: .string)
      _ = pasteboard.setData(Data(), forType: SecretClipboard.concealedType)
    } else {
      _ = pasteboard.clearContents()
      _ = pasteboard.setString(text, forType: .string)
    }
    let changeCount = pasteboard.changeCount
    clearOnExitChangeCount = concealed && clearOnExit ? changeCount : nil
    return changeCount
  }

  /// Empties the pasteboard only if nothing was copied since [changeCount].
  func clear(ifChangeCount changeCount: Int) -> Bool {
    if clearOnExitChangeCount == changeCount {
      clearOnExitChangeCount = nil
    }
    let pasteboard = NSPasteboard.general
    guard pasteboard.changeCount == changeCount else { return false }
    _ = pasteboard.clearContents()
    return true
  }
}

/// One system-wide shortcut, registered through Carbon. Works inside the App
/// Sandbox and needs no Accessibility permission.
final class GlobalHotKey {
  var onPressed: (() -> Void)?
  private var hotKeyRef: EventHotKeyRef?
  private var handlerRef: EventHandlerRef?
  private static let signature: OSType = 0x5053_5445  // 'PSTE'

  /// Returns noErr, or the Carbon error (eventHotKeyExistsErr when another
  /// app holds the combination exclusively).
  func register(keyCode: UInt32, modifiers: UInt32) -> OSStatus {
    unregister()
    if handlerRef == nil {
      var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
      let status = InstallEventHandler(
        GetApplicationEventTarget(),
        { _, _, userData -> OSStatus in
          guard let userData = userData else { return OSStatus(eventNotHandledErr) }
          let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
          DispatchQueue.main.async { hotKey.onPressed?() }
          return noErr
        },
        1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
      if status != noErr {
        return status
      }
    }
    let hotKeyID = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)
    // Carbon hotkeys are shared between apps unless registered exclusively.
    // Exclusive registration takes the combination over from apps that hold it
    // non-exclusively, and fails (so Pastee can say so) if one holds it
    // exclusively.
    return RegisterEventHotKey(
      keyCode, modifiers, hotKeyID, GetApplicationEventTarget(),
      OptionBits(kEventHotKeyExclusive), &hotKeyRef)
  }

  func unregister() {
    if let ref = hotKeyRef {
      UnregisterEventHotKey(ref)
      hotKeyRef = nil
    }
  }

  deinit {
    unregister()
    if let handler = handlerRef {
      RemoveEventHandler(handler)
    }
  }
}
