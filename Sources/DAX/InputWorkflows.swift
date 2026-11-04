import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ImageLine: Identifiable {
    var id = UUID()
    var original: String
    var translated = ""
    var bounds: CGRect
    var error: String?

    func overlayBounds(imageSize: CGSize) -> CGRect {
        let box = CGRect(x: bounds.minX * imageSize.width, y: bounds.minY * imageSize.height,
                         width: bounds.width * imageSize.width, height: bounds.height * imageSize.height)
        return box.insetBy(dx: -2, dy: -2).intersection(CGRect(origin: .zero, size: imageSize))
    }
}

@MainActor
final class ImageItem: ObservableObject, Identifiable {
    let id = UUID()
    let image: CGImage
    let name: String
    @Published var lines: [ImageLine] = []
    @Published var state = "待识别"
    @Published var error: String?
    init(image: CGImage, name: String) { self.image = image; self.name = name }
}

extension AppModel {
    func perform(_ action: InputAction, fromScript: Bool = false) {
        if !fromScript { windowLocationOverride = nil; inputVisibilityOverride = nil; scriptRequestID = nil }
        switch action {
        case .captureTranslate, .captureOCR, .continuousOCR, .silentOCR, .imageTranslate:
            captureScreen(action)
        case .selectedTranslate, .selectedSilent, .fieldSilent:
            cancelCapture()
            cancelImages()
            editTask?.cancel()
            do {
                selectionContext = try SelectedTextReader().capture(wholeField: action == .fieldSilent)
                guard let context = selectionContext else { return }
                originalInput = context.text
                input = normalize(context.text)
                identifyLanguage()
                mode = .translate
                if action == .selectedTranslate { onShow?() }
                submit(origin: "selection", silent: action != .selectedTranslate)
            } catch { fail(error) }
        case .inputTranslate:
            selectionContext = nil
            receive("", origin: "text", translate: false)
            mode = .translate
        case .clipboardTranslate:
            if let image = clipboardImage() { processImage(image, action: .captureTranslate) }
            else if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty { selectionContext = nil; receive(text, origin: "clipboard") }
            else { fail(AppFailure("剪贴板里没有可翻译的文字或图片。")) }
        case .clipboardOCR:
            guard let image = clipboardImage() else { fail(AppFailure("剪贴板里没有图片。")); return }
            processImage(image, action: .captureOCR)
        }
    }
    func cancelCapture() {
        captureRevision = UUID()
        captureTask?.cancel()
        captureTask = nil
        busy = false
    }
    func captureScreen(_ action: InputAction) {
        editTask?.cancel()
        cancelImages()
        let previous = captureTask
        previous?.cancel()
        captureRevision = UUID()
        let revision = captureRevision
        selectionContext = nil
        busy = true
        onHide?()
        captureTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.captureRevision == revision else { return }
            do {
                guard let capture = try await self.capture.capture() else {
                    if self.captureRevision == revision { self.busy = false; self.captureTask = nil }
                    return
                }
                guard !Task.isCancelled, self.captureRevision == revision else { return }
                await self.acceptImage(capture.image, action: action, revision: revision)
            } catch {
                if !Task.isCancelled, self.captureRevision == revision { self.busy = false; self.captureTask = nil; self.fail(error) }
            }
        }
    }
    func processImage(_ image: CGImage, action: InputAction) {
        editTask?.cancel()
        cancelImages()
        let previous = captureTask
        previous?.cancel()
        captureRevision = UUID()
        let revision = captureRevision
        selectionContext = nil
        busy = true
        captureTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.captureRevision == revision else { return }
            await self.acceptImage(image, action: action, revision: revision)
        }
    }
    func recognize(_ image: CGImage) async throws -> OCRDocument {
        if preferences.ocrProvider == "local" {
            return try await ocr.recognize(image, mode: OCRMode(rawValue: preferences.ocrMode) ?? .chineseEnglish, detectCodes: preferences.detectQR)
        }
        let data = try png(image)
        if preferences.ocrProvider == "google" {
            guard let config = services.first(where: { $0.kind == .google }), let key = try await CredentialStore.load(serviceID: config.id) else {
                throw AppFailure("请先配置 Google Cloud 服务密钥。")
            }
            let result = try await CloudOCRService().recognize(imageData: data, apiKey: key)
            guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("所选区域未识别到文字。") }
            let lines = result.regions.map { region in
                OCRLine(text: region.text, bounds: CGRect(x: region.bounds.minX / CGFloat(image.width), y: 1 - region.bounds.maxY / CGFloat(image.height), width: region.bounds.width / CGFloat(image.width), height: region.bounds.height / CGFloat(image.height)))
            }
            return OCRDocument(text: result.text, lines: lines)
        }
        guard let plugin = plugins.first(where: { $0.id == preferences.ocrProvider && $0.enabled }) else { throw AppFailure("OCR 插件未安装或已停用。") }
        let response = try await pluginRuntime.run(plugin: plugin, options: await pluginStore.loadOptions(for: plugin), operation: "ocr", query: [
            "image": ["__daxData": data.base64EncodedString()], "detectFrom": source, "from": source
        ])
        let text = response.text
        guard !text.isEmpty else { throw AppFailure("OCR 服务未识别到文字。") }
        let lines = response.ocrLines.compactMap { item -> OCRLine? in
            guard let text = item["text"] as? String else { return nil }
            if let b = item["boundingBox"] as? [String: Double], let x=b["x"], let y=b["y"], let w=b["width"], let h=b["height"] {
                return OCRLine(text: text, bounds: CGRect(x:x,y:y,width:w,height:h))
            }
            return nil
        }
        return OCRDocument(text: text, lines: lines)
    }
    func acceptImage(_ image: CGImage, action: InputAction, revision: UUID) async {
        do {
            if action == .imageTranslate {
                let item = ImageItem(image: image, name: "截图")
                guard !Task.isCancelled, captureRevision == revision else { return }
                captureTask = nil
                imageItems = [item]
                selectedImage = item.id
                mode = .image
                busy = false
                onShow?()
                startImageTranslation()
                return
            }
            let document = try await recognize(image)
            guard !Task.isCancelled, captureRevision == revision else { return }
            captureTask = nil
            busy = false
            if action == .silentOCR {
                copy(document.text)
                status = "OCR 结果已复制"
                return
            }
            let text = action == .continuousOCR && mode == .ocr && !input.isEmpty ? input + "\n\n" + document.text : document.text
            receive(text, origin: "image", translate: action == .captureTranslate)
        } catch { if !Task.isCancelled, captureRevision == revision { busy = false; captureTask = nil; fail(error) } }
    }
    func importImages(asTranslation: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        openImages(panel.urls, asTranslation: asTranslation)
    }
    func openImages(_ urls: [URL], asTranslation: Bool) {
        scriptRequestID = nil
        guard !urls.isEmpty else { return }
        cancelCapture()
        cancelImages()
        editTask?.cancel()
        selectionContext = nil
        do {
            let items = try urls.map { url -> ImageItem in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw AppFailure("无法打开图片 \(url.lastPathComponent)。") }
                return ImageItem(image: image, name: url.lastPathComponent)
            }
            if asTranslation {
                imageItems = items
                selectedImage = items.first?.id
                mode = .image
                onShow?()
                startImageTranslation()
            } else {
                let revision = captureRevision
                busy = true
                captureTask = Task { [weak self] in
                    guard let self else { return }
                    var texts: [String] = []
                    var failures: [String] = []
                    for item in items {
                        guard !Task.isCancelled, self.captureRevision == revision else { return }
                        do { texts.append(try await self.recognize(item.image).text) }
                        catch is CancellationError { return }
                        catch { failures.append("\(item.name) · \(error.localizedDescription)") }
                    }
                    guard !Task.isCancelled, self.captureRevision == revision else { return }
                    self.captureTask = nil
                    self.busy = false
                    if !texts.isEmpty { self.receive(texts.joined(separator: "\n\n"), origin: "images", translate: false) }
                    if !failures.isEmpty { self.fail(AppFailure(failures.joined(separator: "\n"))) }
                }
            }
        } catch { fail(error) }
    }
    func startImageTranslation(only selectedID: UUID? = nil) {
        imageTask?.cancel()
        imageRevision = UUID()
        let revision = imageRevision
        guard let service = activeServices.first else { fail(AppFailure("请先启用翻译服务。")); return }
        let items = imageItems.filter { selectedID == nil || $0.id == selectedID }
        imageTask = Task { [weak self] in
            guard let self else { return }
            for item in items {
                guard !Task.isCancelled, self.imageRevision == revision else { return }
                item.error = nil
                item.state = "识别中"
                do {
                    let document = try await self.recognize(item.image)
                    guard !Task.isCancelled, self.imageRevision == revision else { return }
                    guard !document.lines.isEmpty else { throw AppFailure("当前 OCR 服务没有返回区域位置，请选择本地 OCR 或支持坐标的服务。") }
                    item.lines = document.lines.map { ImageLine(original: $0.text, bounds: $0.bounds) }
                    item.state = "翻译中"
                    for index in item.lines.indices {
                        try Task.checkCancellation()
                        let text = item.lines[index].original
                        let from = self.source == "auto" ? self.detectLanguage(text) : self.source
                        let to = self.targetLanguage(for: from)
                        do {
                            let output = try await self.performTranslation(text, source: from, target: to, config: service)
                            try Task.checkCancellation()
                            guard self.imageRevision == revision else { return }
                            item.lines[index].translated = output.text
                        } catch is CancellationError { throw CancellationError() }
                        catch { if self.imageRevision == revision { item.lines[index].error = error.localizedDescription } }
                    }
                    item.state = item.lines.contains(where: { $0.error != nil }) ? "部分区域翻译失败" : "已完成"
                } catch is CancellationError { if self.imageRevision == revision { item.state = "已取消" }; return }
                catch { if self.imageRevision == revision { item.error = error.localizedDescription; item.state = "失败" } }
            }
        }
    }
    func retryImageLine(_ item: ImageItem, lineID: UUID) {
        guard let service = activeServices.first,
              let line = item.lines.first(where: { $0.id == lineID }) else { return }
        cancelImages()
        let revision = imageRevision
        item.state = "翻译中"
        imageTask = Task { [weak self] in
            guard let self else { return }
            do {
                let from = self.source == "auto" ? self.detectLanguage(line.original) : self.source
                let to = self.targetLanguage(for: from)
                let output = try await self.performTranslation(line.original, source: from, target: to, config: service)
                guard !Task.isCancelled, self.imageRevision == revision,
                      let index = item.lines.firstIndex(where: { $0.id == lineID && $0.original == line.original }) else { return }
                item.lines[index].translated = output.text
                item.lines[index].error = nil
                item.state = "区域已更新"
            } catch {
                guard !Task.isCancelled, self.imageRevision == revision,
                      let index = item.lines.firstIndex(where: { $0.id == lineID }) else { return }
                item.lines[index].error = error.localizedDescription
                item.state = "区域翻译失败"
            }
        }
    }
    func cancelImages() { imageRevision = UUID(); imageTask?.cancel(); imageItems.filter { $0.state == "翻译中" || $0.state == "识别中" }.forEach { $0.state = "已取消" } }
    func clipboardImage() -> CGImage? {
        guard let image = NSImage(pasteboard: .general) else { return nil }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
    func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw AppFailure("无法编码图片。") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure("图片编码失败。") }
        return data as Data
    }
    func exportImage(_ item: ImageItem) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(item.name)-翻译.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let size = NSSize(width: item.image.width, height: item.image.height)
        guard let context = CGContext(data: nil, width: item.image.width, height: item.image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail(AppFailure("无法创建导出图片。")); return }
        context.draw(item.image, in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for line in item.lines where !line.translated.isEmpty {
            let box = line.overlayBounds(imageSize: size)
            NSColor.white.setFill()
            box.fill()
            let font = NSFont.systemFont(ofSize: overlayFontSize(line.translated, size: box.insetBy(dx: 2, dy: 1).size))
            (line.translated as NSString).draw(in: box.insetBy(dx: 2, dy: 1), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
        NSGraphicsContext.restoreGraphicsState()
        do {
            guard let image = context.makeImage() else { throw AppFailure("导出图片失败。") }
            try png(image).write(to: url, options: .atomic)
        } catch { fail(error) }
    }
}

func overlayFontSize(_ text: String, size: CGSize) -> CGFloat {
    var lower: CGFloat = 2
    var upper = max(lower, min(size.height * 0.8, 28))
    for _ in 0..<10 {
        let candidate = (lower + upper) / 2
        let rect = (text as NSString).boundingRect(with: NSSize(width: max(1, size.width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: candidate)])
        if rect.height <= size.height { lower = candidate } else { upper = candidate }
    }
    return lower
}
