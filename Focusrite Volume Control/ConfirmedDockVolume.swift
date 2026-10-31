//
//  ConfirmedDockVolume.swift
//  Focusrite Volume Control
//
//  The Dock tile reads FC2's slider itself. It never displays an optimistic value.
//

import AppKit
import ApplicationServices
import CoreText

final class ConfirmedDockVolume {
    private let queue = DispatchQueue(label: "focusrite.dock.confirmed-volume", qos: .utility)
    private let readLock = NSLock()
    private var readQueued = false
    private var timer: Timer?
    private var tileView: ConfirmedDockTileView?
    private var latestConfirmed: String?

    /// FC2 can report a slider value it never delivered to the interface.
    /// Main thread only.
    var isFC2Unresponsive = false {
        didSet {
            guard isFC2Unresponsive != oldValue else { return }
            showConfirmed(latestConfirmed)
        }
    }

    // Accessed only on queue.
    private var processID: pid_t = 0
    private var slider: AXUIElement?
    private var observer: AXObserver?

    func start() {
        let view = ConfirmedDockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        tileView = view
        if let icon = NSImage(named: "VolumeControlIcon") {
            NSApp.applicationIconImage = icon
            view.icon = icon
        }
        NSApp.dockTile.contentView = view
        NSApp.dockTile.display()

        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.requestRead()
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        requestRead()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        queue.async { self.resetSlider() }
    }

    private func requestRead() {
        readLock.lock()
        guard !readQueued else {
            readLock.unlock()
            return
        }
        readQueued = true
        readLock.unlock()

        queue.async {
            let confirmed = self.readConfirmedValue()
            self.readLock.lock()
            self.readQueued = false
            self.readLock.unlock()
            DispatchQueue.main.async {
                self.latestConfirmed = confirmed
                self.showConfirmed(confirmed)
            }
        }
    }

    static func displayedValue(confirmed: String?, fc2Unresponsive: Bool) -> String? {
        fc2Unresponsive ? nil : confirmed
    }

    private func showConfirmed(_ confirmed: String?) {
        let shown = Self.displayedValue(confirmed: confirmed, fc2Unresponsive: isFC2Unresponsive)
        if tileView?.confirmedValue != shown {
            tileView?.confirmedValue = shown
            NSApp.dockTile.display()
        }
    }

    private func readConfirmedValue() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        do {
            let slider = try resolveSlider()
            guard let value = try attribute(kAXValueAttribute as CFString, of: slider) as? String,
                  !value.isEmpty else { return nil }
            return value
        } catch {
            resetSlider()
            return nil
        }
    }

    private func resolveSlider() throws -> AXUIElement {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.focusrite.control").first else {
            throw DockReadError.unavailable
        }
        if app.processIdentifier != processID { resetSlider() }
        if let slider { return slider }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.5)
        guard let window = FC2Window.element(in: root) else {
            throw DockReadError.unavailable
        }
        let groups = try elements(kAXChildrenAttribute as CFString, of: window)
            .filter { role(of: $0) == (kAXGroupRole as String) }
        guard groups.count >= 5 else { throw DockReadError.unavailable }
        let playbackGroups = try elements(kAXChildrenAttribute as CFString, of: groups[4])
        guard let playback = playbackGroups.first(where: { name(of: $0) == "Playback 1 - 2" }),
              let level = try elements(kAXChildrenAttribute as CFString, of: playback)
                .first(where: { role(of: $0) == (kAXSliderRole as String) && name(of: $0) == "Level" })
        else { throw DockReadError.unavailable }

        processID = app.processIdentifier
        slider = level
        registerValueObserver(for: level, processID: processID)
        return level
    }

    private func registerValueObserver(for level: AXUIElement, processID: pid_t) {
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let owner = Unmanaged<ConfirmedDockVolume>.fromOpaque(refcon).takeUnretainedValue()
            owner.requestRead()
        }
        var created: AXObserver?
        guard AXObserverCreate(processID, callback, &created) == .success,
              let created else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, level,
                                        kAXValueChangedNotification as CFString,
                                        context) == .success else { return }
        observer = created
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
    }

    private func resetSlider() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            if let slider {
                AXObserverRemoveNotification(observer, slider, kAXValueChangedNotification as CFString)
            }
        }
        observer = nil
        slider = nil
        processID = 0
    }

    private func elements(_ key: CFString, of element: AXUIElement) throws -> [AXUIElement] {
        guard let result = try attribute(key, of: element) as? [AXUIElement] else {
            throw DockReadError.unavailable
        }
        return result
    }

    private func attribute(_ key: CFString, of element: AXUIElement) throws -> CFTypeRef {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key, &result) == .success,
              let result else { throw DockReadError.unavailable }
        return result
    }

    private func role(of element: AXUIElement) -> String? {
        try? attribute(kAXRoleAttribute as CFString, of: element) as? String
    }

    private func name(of element: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
            if let name = try? attribute(key as CFString, of: element) as? String,
               !name.isEmpty { return name }
        }
        return nil
    }

    private enum DockReadError: Error { case unavailable }
}

private final class ConfirmedDockTileView: NSView {
    var icon: NSImage?
    var confirmedValue: String? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon?.draw(in: bounds)

        let number = confirmedValue?
            .replacingOccurrences(of: "dB", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        if Double(number) == -127 {
            drawMuteSymbol()
            return
        }
        let baseFont = NSFont(name: "HelveticaNeue-CondensedBlack", size: 128)
            ?? NSFont.systemFont(ofSize: 128, weight: .heavy)
        let font = NSFont(descriptor: baseFont.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ]), size: 128) ?? baseFont
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black,
            .strokeWidth: -5,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: number,
                                                                      attributes: numberAttributes))
        // Reserve room for a sign and two digits. Every ordinary volume uses
        // the same font size, including when crossing from -9 to -10.
        let reference = CTLineCreateWithAttributedString(NSAttributedString(string: "-88",
                                                                           attributes: numberAttributes))
        let referenceBounds = CTLineGetBoundsWithOptions(reference, .useGlyphPathBounds)
        let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let available = bounds.insetBy(dx: bounds.width * 0.045, dy: bounds.height * 0.045)
        guard glyphBounds.width > 0, glyphBounds.height > 0,
              let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = min(available.width / max(referenceBounds.width, glyphBounds.width),
                        available.height / referenceBounds.height)
        context.saveGState()
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -glyphBounds.midX, y: -glyphBounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawMuteSymbol() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: bounds.minX, y: bounds.minY)
        context.scaleBy(x: bounds.width / 128, y: bounds.height / 128)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.setFillColor(NSColor.white.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(6)
        context.move(to: CGPoint(x: 20, y: 48))
        context.addLine(to: CGPoint(x: 40, y: 48))
        context.addLine(to: CGPoint(x: 76, y: 20))
        context.addLine(to: CGPoint(x: 76, y: 108))
        context.addLine(to: CGPoint(x: 40, y: 80))
        context.addLine(to: CGPoint(x: 20, y: 80))
        context.closePath()
        context.drawPath(using: .fillStroke)

        // Outline the slash so it stays readable over both the white speaker
        // and the colored app icon at small Dock sizes.
        for (color, width) in [(NSColor.black, CGFloat(16)), (NSColor.white, CGFloat(8))] {
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(width)
            context.move(to: CGPoint(x: 22, y: 108))
            context.addLine(to: CGPoint(x: 106, y: 20))
            context.strokePath()
        }
        context.restoreGState()
    }
}
