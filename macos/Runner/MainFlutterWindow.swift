import Carbon.HIToolbox
import Cocoa
import FlutterMacOS

/// Hosts Flutter plus Pastee's small native bridge (channel "pastee/native"):
/// a system-wide summon shortcut, and showing/hiding the app.
class MainFlutterWindow: NSWindow {
  private var nativeChannel: FlutterMethodChannel?
  private let summonHotKey = GlobalHotKey()

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
    NSApp.hide(nil)
  }

  private var isFrontmost: Bool {
    return NSApp.isActive && !NSApp.isHidden && self.isVisible && self.isKeyWindow
  }

  private func toggleFromHotKey() {
    let show = !isFrontmost
    if show {
      showApp()
    } else {
      hideApp()
    }
    nativeChannel?.invokeMethod("onHotKey", arguments: ["shown": show])
  }

  private func showApp() {
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
    default:
      result(FlutterMethodNotImplemented)
    }
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
