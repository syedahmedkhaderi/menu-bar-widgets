import AppKit

/// Compact menu row: icon, slider, percentage.
final class SliderRow: NSView {
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let valueLabel = NSTextField(labelWithString: "")
    var onChange: ((Double) -> Void)?

    init(symbol: String, label: String, level: Double?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        let icon = NSImageView(frame: NSRect(x: 14, y: 4, width: 18, height: 18))
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        icon.contentTintColor = .secondaryLabelColor
        icon.toolTip = label

        slider.frame = NSRect(x: 38, y: 3, width: 128, height: 20)
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        slider.isEnabled = level != nil
        slider.doubleValue = level ?? 0
        slider.toolTip = label

        valueLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 172, y: 5, width: 36, height: 16)

        addSubview(icon)
        addSubview(slider)
        addSubview(valueLabel)
        updateLabel(level)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        updateLabel(slider.doubleValue)
        onChange?(slider.doubleValue)
    }

    private func updateLabel(_ level: Double?) {
        valueLabel.stringValue = level.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
    }
}

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.state = state
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let manager = DisplayManager()
    private let keys = BrightnessKeys()
    private let hud = BrightnessHUD()
    private let defaults = UserDefaults.standard

    private var keysEnabled: Bool {
        get { defaults.bool(forKey: "brightnessKeys") }
        set { defaults.set(newValue, forKey: "brightnessKeys") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["brightnessKeys": true])

        statusItem.autosaveName = "MonitorBrightness"
        statusItem.button?.image = NSImage(systemSymbolName: "sun.max", accessibilityDescription: "Monitor brightness")
        statusItem.button?.toolTip = "External monitor"
        menu.delegate = self
        statusItem.menu = menu

        manager.onChange = { [weak self] in self?.rebuildMenu() }

        keys.handler = { [weak self] direction, fine in
            self?.handleKey(direction, fine: fine) ?? false
        }
        if keysEnabled { enableKeys(prompt: !defaults.bool(forKey: "askedForAccessibility")) }
        rebuildMenu()
    }

    // MARK: Brightness keys

    private func enableKeys(prompt: Bool) {
        if prompt && !BrightnessKeys.isTrusted {
            defaults.set(true, forKey: "askedForAccessibility")
            BrightnessKeys.requestTrust()
        }
        keys.start { [weak self] in self?.rebuildMenu() }
    }

    /// Adjusts the external monitor under the pointer; returns false to let macOS handle the key.
    private func handleKey(_ direction: BrightnessKeys.Direction, fine: Bool) -> Bool {
        guard let screen = NSScreen.underPointer, let id = screen.displayID,
              let display = manager.display(for: id) else { return false }
        let step = fine ? 1.0 / 64 : 1.0 / 16
        let current = display.level ?? 0.5
        let target = min(1, max(0, direction == .up ? current + step : current - step))
        manager.setLevel(target, for: display)
        hud.show(level: target, on: screen)
        return true
    }

    // MARK: Menu

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()

        if manager.displays.isEmpty {
            let item = NSMenuItem(title: "No external monitor found", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for display in manager.displays {
            addControls(for: display, to: menu)
            menu.addItem(.separator())
        }

        menu.addItem(ActionItem("Brightness keys", state: keysEnabled ? .on : .off) { [weak self] in self?.toggleKeys() })
        if keysEnabled && !keys.isRunning {
            menu.addItem(ActionItem("Allow in Accessibility…") { [weak self] in self?.openAccessibility() })
        }
        menu.addItem(ActionItem("Re-detect monitors") { [weak self] in self?.manager.refresh() })
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addControls(for display: ExternalDisplay, to menu: NSMenu) {
        let title = NSMenuItem(title: display.name, action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let row = SliderRow(symbol: "sun.max", label: "Brightness", level: display.level)
        row.onChange = { [weak self] level in self?.manager.setLevel(level, for: display) }
        let item = NSMenuItem()
        item.view = row
        menu.addItem(item)
    }

    private func toggleKeys() {
        keysEnabled.toggle()
        if keysEnabled { enableKeys(prompt: true) } else { keys.stop() }
        rebuildMenu()
    }

    private func openAccessibility() {
        BrightnessKeys.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// Single instance: if another copy is already running, quit quietly.
let bundleID = Bundle.main.bundleIdentifier ?? "com.syed.MonitorBrightness"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != .current }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
