import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

struct CaptureImage {
    let image: CGImage
    let logicalRect: CGRect
}

struct ScreenSnapshot {
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage
}

enum OCRMode: String, Codable, CaseIterable, Identifiable {
    case chineseEnglish
    case systemExtended
    var id: String { rawValue }
    var title: String { self == .chineseEnglish ? "中文与英文" : "系统扩展语言" }
}

struct OCRLine: Codable, Identifiable {
    var id: UUID = UUID()
    let text: String
    /// Vision-normalized coordinates with origin at the lower-left of the image.
    let bounds: CGRect
}

struct OCRDocument: Codable {
    let text: String
    let lines: [OCRLine]
    var barcodes: [String] = []

    init(text: String, lines: [OCRLine], barcodes: [String] = []) {
        self.text = text
        self.lines = lines
        self.barcodes = barcodes
    }

    private enum CodingKeys: String, CodingKey { case text, lines, barcodes }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        lines = try container.decode([OCRLine].self, forKey: .lines)
        barcodes = try container.decodeIfPresent([String].self, forKey: .barcodes) ?? []
    }
}

enum CaptureFailure: LocalizedError {
    case permissionRequired, alreadyCapturing, displayUnavailable, selectionTooLarge, captureFailed
    case noText, recognitionFailed, recognitionTimedOut, helperUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "需要屏幕录制权限。请在系统设置中允许 DAX，然后按系统提示重新打开应用。"
        case .alreadyCapturing: return "请先完成或取消当前截图。"
        case .displayUnavailable: return "无法读取所选显示器，请检查屏幕连接。"
        case .selectionTooLarge: return "所选区域过大，请缩小区域后重试。"
        case .captureFailed: return "无法读取屏幕内容，请检查录屏权限后重新选择区域。"
        case .noText: return "所选区域未识别到文字，可以重新截图或手动输入。"
        case .recognitionFailed: return "文字识别失败，请更换区域或识别语言后重试。"
        case .recognitionTimedOut: return "系统文字识别超时，本次任务已结束，可以重试或切换识别语言。"
        case .helperUnavailable: return "无法启动本地识别进程，请重新打开 DAX。"
        }
    }
}

@MainActor
final class CaptureController {
    private var selection: RegionSelection?
    private var hasRequestedPermission = false

    func capture() async throws -> CaptureImage? {
        try Task.checkCancellation()
        guard selection == nil else { throw CaptureFailure.alreadyCapturing }
        if !CGPreflightScreenCaptureAccess() {
            guard !hasRequestedPermission else { throw CaptureFailure.permissionRequired }
            hasRequestedPermission = true
            guard CGRequestScreenCaptureAccess() else { throw CaptureFailure.permissionRequired }
        }
        try Task.checkCancellation()
        
        let snapshots = try await captureScreens()
        
        try Task.checkCancellation()
        let selector = RegionSelection(snapshots: snapshots)
        selection = selector
        defer { selection = nil }
        let rect = await withTaskCancellationHandler {
            await selector.choose()
        } onCancel: {
            Task { @MainActor in selector.cancel() }
        }
        try Task.checkCancellation()
        guard let rect, rect.width >= 4, rect.height >= 4 else { return nil }
        
        do {
            return CaptureImage(image: try Self.compose(rect: rect, snapshots: snapshots), logicalRect: rect)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CaptureFailure {
            throw error
        } catch {
            throw CaptureFailure.captureFailed
        }
    }

    static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    private func captureScreens() async throws -> [ScreenSnapshot] {
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApplications = available.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var snapshots: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            try Task.checkCancellation()
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = available.displays.first(where: { $0.displayID == number.uint32Value }) else { throw CaptureFailure.displayUnavailable }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(ceil(screen.frame.width * screen.backingScaleFactor))
            configuration.height = Int(ceil(screen.frame.height * screen.backingScaleFactor))
            guard configuration.width * configuration.height <= 50_000_000 else { throw CaptureFailure.selectionTooLarge }
            configuration.showsCursor = false
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots.append(ScreenSnapshot(frame: screen.frame, scale: screen.backingScaleFactor, image: image))
        }
        return snapshots
    }

    static func compose(rect: CGRect, snapshots: [ScreenSnapshot]) throws -> CGImage {
        let screens = snapshots.filter { $0.frame.intersects(rect) }
        guard !screens.isEmpty else { throw CaptureFailure.displayUnavailable }
        let scale = screens.map(\.scale).max() ?? 1
        let width = Int(ceil(rect.width * scale)), height = Int(ceil(rect.height * scale))
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 50_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.selectionTooLarge }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for screen in screens {
            let part = rect.intersection(screen.frame)
            let source = CGRect(x: (part.minX - screen.frame.minX) * screen.scale,
                                y: (screen.frame.maxY - part.maxY) * screen.scale,
                                width: part.width * screen.scale, height: part.height * screen.scale).integral
            guard let cropped = screen.image.cropping(to: source) else { throw CaptureFailure.captureFailed }
            let destination = CGRect(x: (part.minX - rect.minX) * scale, y: (part.minY - rect.minY) * scale,
                                     width: part.width * scale, height: part.height * scale)
            context.draw(cropped, in: destination)
        }
        guard let image = context.makeImage() else { throw CaptureFailure.captureFailed }
        return image
    }

}

/// Each request runs in a fresh process so a stalled Vision model can be terminated.
struct OCRRecognizer {
    func recognize(_ image: CGImage, mode: OCRMode = .chineseEnglish, detectCodes: Bool = true) async throws -> OCRDocument {
        let document = try await perform(image, mode: mode, detectCodes: detectCodes, barcodesOnly: false)
        guard !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureFailure.noText }
        return document
    }

    func recognizeCodes(_ image: CGImage) async throws -> [String] {
        try await perform(image, mode: .chineseEnglish, detectCodes: true, barcodesOnly: true).barcodes
    }

    private func perform(_ image: CGImage, mode: OCRMode, detectCodes: Bool, barcodesOnly: Bool) async throws -> OCRDocument {
        guard let executable = Bundle.main.executableURL else { throw CaptureFailure.helperUnavailable }
        let imageData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(imageData, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureFailure.recognitionFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.recognitionFailed }
        let output: Data
        do {
            output = try await OCRProcessJob().run(executable: executable, mode: mode, input: imageData as Data,
                                                   detectCodes: detectCodes, barcodesOnly: barcodesOnly)
        } catch CaptureFailure.recognitionTimedOut where mode == .chineseEnglish {
            try Task.checkCancellation()
            output = try await OCRProcessJob().run(executable: executable, mode: mode, input: imageData as Data,
                                                   detectCodes: detectCodes, barcodesOnly: barcodesOnly)
        }
        guard let envelope = try? JSONDecoder().decode(OCRWorkerEnvelope.self, from: output) else {
            throw CaptureFailure.recognitionFailed
        }
        guard let document = envelope.document else { throw CaptureFailure.recognitionFailed }
        return document
    }
}

private struct OCRWorkerEnvelope: Codable {
    let document: OCRDocument?
    let failed: Bool
}

/// Call before NSApplication initialization. Returns true only in an OCR worker process.
enum OCRWorker {
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        let codesOnly = arguments.contains("--barcode-worker")
        guard codesOnly || arguments.contains("--ocr-worker") else { return false }
        let mode = arguments.count > 2 ? OCRMode(rawValue: arguments[2]) ?? .chineseEnglish : .chineseEnglish
        let detectCodes = codesOnly || arguments.contains("--detect-codes")
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let envelope: OCRWorkerEnvelope
        do {
            guard data.count <= 200_000_000,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CaptureFailure.recognitionFailed
            }
            if detectCodes {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let codes = (request.results ?? []).compactMap(\.payloadStringValue)
                if codesOnly || !codes.isEmpty {
                    let lines = (request.results ?? []).compactMap { observation -> OCRLine? in
                        guard let value = observation.payloadStringValue else { return nil }
                        return OCRLine(text: value, bounds: observation.boundingBox)
                    }
                    let result = OCRWorkerEnvelope(document: OCRDocument(text: codes.joined(separator: "\n"), lines: lines, barcodes: codes), failed: false)
                    if let encoded = try? JSONEncoder().encode(result) { try? FileHandle.standardOutput.write(contentsOf: encoded) }
                    return true
                }
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            switch mode {
            case .chineseEnglish:
                request.revision = VNRecognizeTextRequestRevision2
                let supported = try request.supportedRecognitionLanguages()
                request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"].filter { supported.contains($0) }
            case .systemExtended:
                request.revision = VNRecognizeTextRequestRevision3
                request.automaticallyDetectsLanguage = true
            }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let observations = (request.results ?? []).sorted {
                if $0.boundingBox.maxY != $1.boundingBox.maxY { return $0.boundingBox.maxY > $1.boundingBox.maxY }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            let lines = observations.compactMap { observation -> OCRLine? in
                guard let text = observation.topCandidates(1).first?.string, !text.isEmpty else { return nil }
                return OCRLine(text: text, bounds: observation.boundingBox)
            }
            let text = lines.map(\.text).joined(separator: "\n")
            envelope = OCRWorkerEnvelope(document: OCRDocument(text: text, lines: lines), failed: false)
        } catch {
            envelope = OCRWorkerEnvelope(document: nil, failed: true)
        }
        if let result = try? JSONEncoder().encode(envelope) {
            try? FileHandle.standardOutput.write(contentsOf: result)
        }
        return true
    }
}

private final class OCRProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var terminal: Result<Data, Error>?
    private var process: Process?

    func run(executable: URL, mode: OCRMode, input: Data, detectCodes: Bool, barcodesOnly: Bool) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let terminal {
                    lock.unlock()
                    continuation.resume(with: terminal)
                    return
                }
                self.continuation = continuation
                let process = Process()
                process.executableURL = executable
                process.arguments = [barcodesOnly ? "--barcode-worker" : "--ocr-worker", mode.rawValue]
                if detectCodes { process.arguments?.append("--detect-codes") }
                let inputPipe = Pipe()
                let outputPipe = Pipe()
                process.standardInput = inputPipe
                process.standardOutput = outputPipe
                process.standardError = FileHandle.nullDevice
                self.process = process
                do {
                    try process.run()
                } catch {
                    lock.unlock()
                    finish(.failure(CaptureFailure.helperUnavailable))
                    return
                }
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try inputPipe.fileHandleForWriting.write(contentsOf: input)
                        try inputPipe.fileHandleForWriting.close()
                        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        if process.terminationStatus == 0 { self.finish(.success(data)) }
                        else { self.finish(.failure(CaptureFailure.recognitionFailed)) }
                    } catch {
                        try? inputPipe.fileHandleForWriting.close()
                        self.finish(.failure(CaptureFailure.recognitionFailed), terminate: true)
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
                    self.finish(.failure(CaptureFailure.recognitionTimedOut), terminate: true)
                }
            }
        } onCancel: {
            self.finish(.failure(CancellationError()), terminate: true)
        }
    }

    private func finish(_ result: Result<Data, Error>, terminate: Bool = false) {
        lock.lock()
        guard terminal == nil else { lock.unlock(); return }
        terminal = result
        let continuation = self.continuation
        self.continuation = nil
        let process = self.process
        self.process = nil
        lock.unlock()
        if terminate, let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        continuation?.resume(with: result)
    }
}

@MainActor
final class RegionSelection {
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var start: CGPoint?
    private var current: CGPoint?
    private var cursorPushed = false
    private var dragEventCount = 0
    private let snapshots: [ScreenSnapshot]

    init(snapshots: [ScreenSnapshot]) { self.snapshots = snapshots }

    func choose() async -> CGRect? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            guard !NSScreen.screens.isEmpty else { finish(nil); return }
            for screen in snapshots {
                let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "DAX 截图 · 拖动选择区域，Esc 取消"
                panel.level = .screenSaver
                panel.backgroundColor = .clear
                panel.isOpaque = false
                panel.hasShadow = false
                panel.isMovable = false
                panel.hidesOnDeactivate = false
                panel.animationBehavior = .none
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
                view.selection = self
                view.background = NSImage(cgImage: screen.image, size: screen.frame.size)
                panel.contentView = view
                // Prepare the frozen frame before the panel becomes visible.
                panel.displayIfNeeded()
                panels.append(panel)
            }
            // A nonactivating panel receives selection input without switching apps,
            // changing menu bars, or moving away from the current full-screen Space.
            panels.forEach { $0.orderFrontRegardless() }
            let keyPanel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels[0]
            keyPanel.makeKey()
            keyPanel.makeFirstResponder(keyPanel.contentView)
            NSCursor.crosshair.push()
            cursorPushed = true
        }
    }

    func begin(_ point: CGPoint) { dragEventCount = 0; start = point; current = point; redraw() }
    func drag(_ point: CGPoint) { guard start != nil else { return }; dragEventCount += 1; current = point; redraw() }
    func end(_ point: CGPoint) {
        
        guard start != nil else { return }
        // Commit the rectangle already drawn on screen. A delayed mouse-up can carry a stale location.
        if dragEventCount == 0 { current = point }
        guard let selected = rect, selected.width >= 4, selected.height >= 4 else {
            start = nil
            current = nil
            redraw()
            return
        }
        finish(selected)
    }
    func cancel() { finish(nil) }
    var rect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(start.x - current.x), height: abs(start.y - current.y))
    }
    private func redraw() { panels.forEach { $0.contentView?.needsDisplay = true } }
    private func finish(_ rect: CGRect?) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        if cursorPushed { NSCursor.pop(); cursorPushed = false }
        continuation.resume(returning: rect)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class SelectionView: NSView {
    weak var selection: RegionSelection?
    var background: NSImage?
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        selection?.begin(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        selection?.drag(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func mouseUp(with event: NSEvent) {
        guard let window else { return }
        selection?.end(window.convertPoint(toScreen: event.locationInWindow))
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { selection?.cancel() } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        background?.draw(in: bounds)
        guard let selection, let window else { return }
        let local: CGRect
        if let global = selection.rect, !global.isEmpty {
            local = global.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY).intersection(bounds)
        } else {
            // Outline the display while waiting for the user to drag a region.
            local = bounds
        }
        guard !local.isNull, !local.isEmpty else { return }
        NSColor.systemBlue.setStroke()
        let border = NSBezierPath(rect: local.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }
}
