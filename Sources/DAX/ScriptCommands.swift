import AppKit

struct ScriptRequest {
    let path: String
    let action: String
    let body: [String: Any]

    init(_ json: String) throws {
        guard json.utf8.count <= 32 * 1024 * 1024,
              let data = json.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String else { throw AppFailure("请求需要 JSON 对象和 path。") }
        self.path = path
        body = object["body"] as? [String: Any] ?? [:]
        action = body["action"] as? String ?? ""
    }
}

extension AppModel {
    func handleScript(_ request: ScriptRequest) throws -> [String: Any] {
        if request.path == "status" {
            return ["pid": ProcessInfo.processInfo.processIdentifier, "bundle": Bundle.main.bundleURL.path, "requestID": scriptRequestID ?? "", "queryID": queryID.uuidString, "busy": busy || isTranslating || imageItems.contains { $0.state == "识别中" || $0.state == "翻译中" }, "text": input,
                    "error": isError ? status : "",
                    "images": imageItems.map { item -> [String: Any] in
                        ["id": item.id.uuidString, "state": item.state, "error": item.error ?? "",
                         "regions": item.lines.map { ["translated": !$0.translated.isEmpty, "error": $0.error ?? ""] }]
                    },
                    "results": results.map { result -> [String: Any] in
                        ["serviceID": result.id.uuidString, "name": result.name, "state": result.state.rawValue,
                         "text": result.output?.text ?? "", "error": result.error ?? ""]
                    }]
        }
        if request.path == "cancel" { closeResult(); return ["cancelled": true] }
        guard request.path == "translate" || request.path == "ocr" else { throw AppFailure("不支持的脚本 path。") }
        windowLocationOverride = request.body["windowLocation"] as? String
        switch request.body["inputBoxState"] as? String {
        case "alwaysFold": inputVisibilityOverride = false
        case "alwaysUnfold": inputVisibilityOverride = true
        default: inputVisibilityOverride = nil
        }
        let actions: [String: InputAction] = request.path == "translate" ? [
            "selectionTranslate": .selectedTranslate, "silentSelectionTranslate": .selectedSilent,
            "silentInputBoxTranslate": .fieldSilent, "snipTranslate": .captureTranslate,
            "inputTranslate": .inputTranslate, "pasteboardTranslate": .clipboardTranslate
        ] : ["snipOCR": request.body["isSilent"] as? Bool == true ? .silentOCR : .captureOCR,
             "continuousOCR": .continuousOCR, "pasteboardOCR": .clipboardOCR]
        if let action = actions[request.action] {
            perform(action, fromScript: true)
        } else if request.path == "translate", request.action == "translateText" {
            guard let text = request.body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppFailure("translateText 需要非空的 text。") }
            receive(text, origin: "script")
        } else if request.action == "showWindow" {
            onShow?()
        } else if (request.path == "translate" && request.action == "translateImage") || (request.path == "ocr" && request.action == "ocrImage") {
            guard let base64 = request.body["imageBase64"] as? String, let data = Data(base64Encoded: base64),
                  let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AppFailure("imageBase64 需要有效的图片数据。") }
            let action: InputAction = request.path == "translate" ? .captureTranslate : (request.body["isSilent"] as? Bool == true ? .silentOCR : .captureOCR)
            processImage(image, action: action)
        } else {
            throw AppFailure("不支持的脚本 action。")
        }
        let requestID = UUID().uuidString
        scriptRequestID = requestID
        return ["accepted": true, "requestID": requestID, "queryID": queryID.uuidString]
    }
}

@objc(DAXRequestCommand)
final class DAXRequestCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            do {
                guard let model = AppEnvironment.model else { throw AppFailure("DAX 尚未启动完成。") }
                guard let json = directParameter as? String else { throw AppFailure("request 需要 JSON 字符串。") }
                let response = try model.handleScript(ScriptRequest(json))
                return String(data: try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]), encoding: .utf8)
            } catch {
                scriptErrorNumber = -1700
                scriptErrorString = error.localizedDescription
                return nil
            }
        }
    }
}

@objc(DAXTranslateCommand)
final class DAXTranslateCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated {
            guard let text = directParameter as? String, !text.isEmpty, let model = AppEnvironment.model else {
                scriptErrorNumber = -1700
                scriptErrorString = "translate 需要非空文字和运行中的 DAX。"
                return nil
            }
            model.receive(text, origin: "script")
            return model.queryID.uuidString
        }
    }
}
