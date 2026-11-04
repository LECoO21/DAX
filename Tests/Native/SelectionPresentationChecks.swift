import AppKit

@main struct SelectionPresentationChecks {
    @MainActor static var failures: [String] = []
    @MainActor static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message); print("FAIL \(message)") }
    }
    @MainActor static func render(_ view: NSView) -> NSBitmapImageRep {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            Task { @MainActor in
                await runChecks()
                let code: Int32 = failures.isEmpty ? 0 : 1
                if code == 0 { print("PASS selection presentation: idle screen outline, click recovery, drag outline, undimmed pixels, stable foreground, stale mouse-up and Escape") }
                exit(code)
            }
        }
        app.run()
    }
    @MainActor static func runChecks() async {
        let foreground = NSWorkspace.shared.frontmostApplication
        defer { if let foreground, foreground.processIdentifier != ProcessInfo.processInfo.processIdentifier { foreground.activate(options: []) } }
        let screen = NSScreen.screens[0]
        let frame = CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 320, height: 200)
        let context = CGContext(data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        let snapshot = ScreenSnapshot(frame: frame, scale: 2, image: context.makeImage()!)
        let selector = RegionSelection(snapshots: [snapshot])
        let result = Task { await selector.choose() }
        let selectionTimeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)); selector.cancel() } catch {}
        }
        defer { selectionTimeout.cancel() }
        try? await Task.sleep(for: .milliseconds(150))
        guard let panel = NSApp.windows.first(where: { $0.isVisible && $0.contentView is SelectionView }),
              let view = panel.contentView as? SelectionView else { check(false, "selection panel appears"); selector.cancel(); return }
        check(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground?.processIdentifier, "selection preserves the frontmost application")
        check(panel.styleMask.contains(.nonactivatingPanel), "selection panel does not activate DAX")
        check(panel.animationBehavior == .none, "selection has no window animation")
        check(panel.isKeyWindow && panel.firstResponder === view, "inactive panel receives keyboard input")
        check(!panel.isMovable && !view.mouseDownCanMoveWindow, "drag cannot move selection window")
        let before = render(view)
        let white = before.colorAt(x: 10, y: 10)!.usingColorSpace(.deviceRGB)!
        check(white.redComponent > 0.99 && white.greenComponent > 0.99 && white.blueComponent > 0.99, "screen is not dimmed before dragging")
        func hasScreenOutline(_ bitmap: NSBitmapImageRep) -> Bool {
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            let edgePoints = [CGPoint(x: 1, y: 100), CGPoint(x: 319, y: 100),
                              CGPoint(x: 160, y: 1), CGPoint(x: 160, y: 199)]
            return edgePoints.allSatisfy { point in
                let pixel = bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))!.usingColorSpace(.deviceRGB)!
                return pixel.blueComponent > 0.6 && pixel.redComponent < 0.4
            }
        }
        check(hasScreenOutline(before), "waiting for selection outlines all four screen edges")
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let down = mouse(.leftMouseDown, CGPoint(x: 40, y: 40))
        check(view.acceptsFirstMouse(for: down), "first click starts selection")
        NSApp.sendEvent(down)
        check(hasScreenOutline(render(view)), "mouse-down without dragging keeps the screen outline")
        NSApp.sendEvent(mouse(.leftMouseUp, CGPoint(x: 40, y: 40)))
        check(selector.rect == nil && panel.isVisible, "a click without dragging waits for a valid selection")
        check(hasScreenOutline(render(view)), "invalid selection restores the screen outline")
        NSApp.sendEvent(down)
        NSApp.sendEvent(mouse(.leftMouseDragged, CGPoint(x: 200, y: 140)))
        let expected = CGRect(x: frame.minX + 40, y: frame.minY + 40, width: 160, height: 100)
        check(selector.rect == expected, "drag tracks screen coordinates")
        let selected = render(view)
        let scale = CGFloat(selected.pixelsWide) / view.bounds.width
        func color(_ x: CGFloat, _ y: CGFloat) -> NSColor {
            selected.colorAt(x: Int(x * scale), y: Int((view.bounds.height - y) * scale))!.usingColorSpace(.deviceRGB)!
        }
        for point in [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 80), CGPoint(x: 250, y: 170),
                      CGPoint(x: 1, y: 100), CGPoint(x: 319, y: 100), CGPoint(x: 160, y: 1), CGPoint(x: 160, y: 199)] {
            let pixel = color(point.x, point.y)
            check(pixel.redComponent > 0.99 && pixel.greenComponent > 0.99 && pixel.blueComponent > 0.99, "inside and outside selection retain original brightness")
        }
        let blue = color(41, 80)
        check(blue.blueComponent > 0.6 && blue.redComponent < 0.4, "selection has a blue outline")
        NSApp.sendEvent(mouse(.leftMouseUp, .zero))
        check(await result.value == expected, "mouse-up commits the drawn rectangle")
        selectionTimeout.cancel()
        check(!panel.isVisible, "selection closes after mouse-up")
        let cancelled = Task { await selector.choose() }
        let cancelTimeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(5)); selector.cancel() } catch {}
        }
        defer { cancelTimeout.cancel() }
        try? await Task.sleep(for: .milliseconds(100))
        guard let keyWindow = NSApp.keyWindow else { check(false, "selection can be reopened"); selector.cancel(); return }
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: keyWindow.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(escape)
        check(!keyWindow.isVisible, "Escape closes the panel")
        selector.cancel()
        check(await cancelled.value == nil, "Escape cancels without a selected region")
    }
}
