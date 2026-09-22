import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = Model()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private lazy var hosting = NSHostingView(rootView: PopoverView(model: model))
    private var lastStatus = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu (rather than NSPopover) always anchors correctly under the status item.
        hosting.setFrameSize(hosting.fittingSize)
        let item = NSMenuItem()
        item.view = hosting
        menu.addItem(item)
        menu.delegate = self

        statusItem.autosaveName = "SysMeter"
        statusItem.button?.imagePosition = .imageOnly
        statusItem.menu = menu

        model.onDisplayChange = { [weak self] in self?.updateStatusItem() }
        model.onLayoutChange = { [weak self] in
            // Let SwiftUI apply the change first, then resize the menu item to the new content.
            DispatchQueue.main.async { self?.fitMenuToContent() }
        }
        model.start()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.setPopoverVisible(true)
        fitMenuToContent()
    }
    func menuDidClose(_ menu: NSMenu) { model.setPopoverVisible(false) }

    private func fitMenuToContent() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        if size.height > 0, size != hosting.frame.size { hosting.setFrameSize(size) }
    }

    private func updateStatusItem() {
        let cpu = model.latestCPU, memory = model.latestMemory, battery = model.latestBattery
        var parts: [StatusImage.Part] = []
        if model.showCPU { parts.append(.init(lead: .symbol("cpu"), text: percent(cpu.total))) }
        if model.showMemory { parts.append(.init(lead: .label("RAM"), text: percent(memory.usage))) }
        if model.showBattery && battery.present {
            parts.append(.init(lead: .symbol(batterySymbol(battery)), text: percent(battery.level)))
        }
        if parts.isEmpty { parts.append(.init(lead: .symbol("gauge.with.dots.needle.50percent"), text: "")) }

        // Only redraw when something visible changed.
        let key = parts.map { "\($0.lead)\($0.text)" }.joined()
        guard key != lastStatus else { return }
        lastStatus = key
        statusItem.button?.image = StatusImage.render(parts)
        statusItem.button?.toolTip = "CPU \(percent(cpu.total)) · Memory \(percent(memory.usage))"
            + (battery.present ? " · Battery \(percent(battery.level))" : "")
    }
}

/// Draws "icon value  RAM value" into one template image so it adapts to light/dark menu bars.
enum StatusImage {
    enum Lead { case symbol(String), label(String) }
    struct Part { let lead: Lead; let text: String }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let labelFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    private static let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)

    static func render(_ parts: [Part]) -> NSImage {
        let height: CGFloat = 18
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: labelFont, .foregroundColor: NSColor.black]
        // Fixed-width text slot ("100%") so the item doesn't jitter as numbers change.
        let slot = ("100%" as NSString).size(withAttributes: attrs).width
        let gap: CGFloat = 3, spacing: CGFloat = 8

        func leadWidth(_ lead: Lead) -> CGFloat {
            switch lead {
            case .symbol(let name):
                return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig)?.size.width ?? 0
            case .label(let text):
                return (text as NSString).size(withAttributes: labelAttrs).width
            }
        }

        let width = parts.reduce(0) { $0 + leadWidth($1.lead) + ($1.text.isEmpty ? 0 : gap + slot) }
            + spacing * CGFloat(max(parts.count - 1, 0))

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                switch part.lead {
                case .symbol(let name):
                    if let icon = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(symbolConfig) {
                        icon.draw(in: NSRect(x: x, y: (height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
                    }
                case .label(let text):
                    let size = (text as NSString).size(withAttributes: labelAttrs)
                    (text as NSString).draw(at: NSPoint(x: x, y: (height - size.height) / 2), withAttributes: labelAttrs)
                }
                x += leadWidth(part.lead)
                if !part.text.isEmpty {
                    let size = (part.text as NSString).size(withAttributes: attrs)
                    (part.text as NSString).draw(at: NSPoint(x: x + gap + slot - size.width, y: (height - size.height) / 2), withAttributes: attrs)
                    x += gap + slot
                }
                x += spacing
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

// Single instance: if another copy is already running, quit quietly.
let bundleID = Bundle.main.bundleIdentifier ?? "com.syed.SysMeter"
if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0 != .current }) {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
