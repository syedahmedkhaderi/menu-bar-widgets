import AppKit
import ApplicationServices

/// Intercepts the keyboard brightness keys while the pointer is on an external monitor.
/// On the built-in screen the keys pass through to macOS untouched.
final class BrightnessKeys {
    enum Direction { case up, down }

    /// Return true to consume the key press.
    var handler: ((Direction, _ fine: Bool) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var consumedLastKeyDown = false

    private static let systemDefinedType = CGEventType(rawValue: 14)!   // NX_SYSDEFINED
    private static let auxControlSubtype: Int16 = 8                     // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let brightnessUp = 2                                 // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown = 3                               // NX_KEYTYPE_BRIGHTNESS_DOWN

    var isRunning: Bool { tap != nil }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Starts the tap, retrying until Accessibility access is granted.
    func start(onStateChange: @escaping () -> Void) {
        guard tap == nil else { return }
        if createTap() {
            onStateChange()
            return
        }
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if self.createTap() {
                timer.invalidate()
                self.retryTimer = nil
                onStateChange()
            }
        }
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func createTap() -> Bool {
        guard BrightnessKeys.isTrusted else { return false }
        let mask = CGEventMask(1) << CGEventMask(BrightnessKeys.systemDefinedType.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let keys = Unmanaged<BrightnessKeys>.fromOpaque(context).takeUnretainedValue()
            return keys.handle(type: type, event: event)
        }, userInfo: context) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == BrightnessKeys.systemDefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == BrightnessKeys.auxControlSubtype else {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        guard keyCode == BrightnessKeys.brightnessUp || keyCode == BrightnessKeys.brightnessDown else {
            return Unmanaged.passUnretained(event)
        }
        let isKeyDown = ((nsEvent.data1 & 0xFF00) >> 8) == 0x0A
        let direction: Direction = keyCode == BrightnessKeys.brightnessUp ? .up : .down
        let fine = nsEvent.modifierFlags.contains([.option, .shift])

        // Decide on key-down; swallow the matching key-up too so macOS never sees half a press.
        if isKeyDown {
            consumedLastKeyDown = handler?(direction, fine) == true
        }
        return consumedLastKeyDown ? nil : Unmanaged.passUnretained(event)
    }
}
