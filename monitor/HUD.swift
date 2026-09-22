import AppKit

/// A small brightness overlay shown on the monitor being adjusted, similar to the macOS one.
final class BrightnessHUD {
    private let panel: NSPanel
    private let bar = NSProgressIndicator()
    private var hideWork: DispatchWorkItem?
    private var generation = 0

    init() {
        let size = NSSize(width: 220, height: 56)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let icon = NSImageView(frame: NSRect(x: 16, y: 16, width: 24, height: 24))
        icon.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Brightness")?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .medium))
        icon.contentTintColor = .labelColor

        bar.frame = NSRect(x: 52, y: 20, width: 150, height: 16)
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1

        background.addSubview(icon)
        background.addSubview(bar)
        panel.contentView = background
    }

    func show(level: Double, on screen: NSScreen) {
        bar.doubleValue = level
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.minY + 80))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        generation += 1
        let shownGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                self?.panel.animator().alphaValue = 0
            }, completionHandler: {
                // A newer key press may have re-shown the HUD mid-fade.
                guard let self, self.generation == shownGeneration else { return }
                self.panel.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
