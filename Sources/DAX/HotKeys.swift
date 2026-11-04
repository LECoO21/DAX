import AppKit
import ApplicationServices
import Carbon

@MainActor
final class HotKeyManager {
    var onTrigger: (() -> Void)?
    private static var nextIdentifier: UInt32 = 1
    private let signature: OSType = 0x44415848
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var keyCode: UInt32?
    private var modifiers: UInt32?
    private var identifier: UInt32?

    func register(keyCode: UInt32, modifiers: UInt32) throws {
        if hotKey != nil, self.keyCode == keyCode, self.modifiers == modifiers { return }
        try installHandler()
        let next = Self.nextIdentifier
        Self.nextIdentifier = next == UInt32.max ? 1 : next + 1
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers,
                                         EventHotKeyID(signature: signature, id: next),
                                         GetApplicationEventTarget(), 0, &candidate)
        guard status == noErr, let candidate else { throw HotKeyFailure.registration }
        let previous = hotKey
        hotKey = candidate
        identifier = next
        self.keyCode = keyCode
        self.modifiers = modifiers
        if let previous { UnregisterEventHotKey(previous) }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        identifier = nil
        keyCode = nil
        modifiers = nil
    }

    private func installHandler() throws {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), daxHotKeyCallback,
                                         1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { throw HotKeyFailure.installation }
    }

    fileprivate func receive(_ event: EventHotKeyID) -> Bool {
        guard event.signature == signature, event.id == identifier else { return false }
        onTrigger?()
        return true
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

private let daxHotKeyCallback: EventHandlerUPP = { _, event, context in
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return status }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(context).takeUnretainedValue()
    return MainActor.assumeIsolated {
        manager.receive(identifier) ? noErr : OSStatus(eventNotHandledErr)
    }
}

private enum HotKeyFailure: LocalizedError {
    case registration, installation
    var errorDescription: String? {
        switch self {
        case .registration: return "该快捷键无法注册，可能已被其他应用使用。请更换组合，原有可用快捷键仍保留。"
        case .installation: return "无法启用全局快捷键，可先从菜单栏进入。"
        }
    }
}

@MainActor
struct SelectedTextReader {
    func read(from application: NSRunningApplication? = nil) throws -> String {
        try capture(from: application).text
    }

    func capture(from application: NSRunningApplication? = nil, wholeField: Bool = false) throws -> SelectionContext {
        guard AXIsProcessTrusted() else { throw SelectedTextFailure.permissionRequired }
        guard let application = application ?? NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw SelectedTextFailure.noSelection
        }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var rawElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &rawElement) == .success,
              let rawElement, CFGetTypeID(rawElement) == AXUIElementGetTypeID() else {
            throw SelectedTextFailure.noSelection
        }
        let element = unsafeBitCast(rawElement, to: AXUIElement.self)
        let fullText = Self.stringAttribute(element, kAXValueAttribute)
        let selectedText = Self.stringAttribute(element, kAXSelectedTextAttribute)
        let text = wholeField ? fullText : selectedText
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectedTextFailure.noSelection
        }
        return SelectionContext(application: application, element: element, text: text,
                                fullText: fullText, selection: Self.selectedRange(element), wholeField: wholeField)
    }

    static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    fileprivate static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    fileprivate static func selectedRange(_ element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }
}

@MainActor
final class SelectionContext {
    let text: String
    private let application: NSRunningApplication
    private let element: AXUIElement
    private let fullText: String?
    private let selection: CFRange?
    private let wholeField: Bool

    fileprivate init(application: NSRunningApplication, element: AXUIElement, text: String,
                     fullText: String?, selection: CFRange?, wholeField: Bool) {
        self.application = application
        self.element = element
        self.text = text
        self.fullText = fullText
        self.selection = selection
        self.wholeField = wholeField
    }

    var canReplace: Bool {
        var settable: DarwinBoolean = false
        let attribute = wholeField ? kAXValueAttribute : kAXSelectedTextAttribute
        if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success,
           settable.boolValue { return true }
        guard !wholeField, fullText != nil, selection != nil else { return false }
        return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    func replace(with replacement: String) throws {
        guard AXIsProcessTrusted() else { throw SelectedTextFailure.permissionRequired }
        guard !application.isTerminated else { throw SelectedTextFailure.targetChanged }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFEqual(focused, element) else { throw SelectedTextFailure.targetChanged }
        guard SelectedTextReader.stringAttribute(element, kAXValueAttribute) == fullText else {
            throw SelectedTextFailure.targetChanged
        }
        if !wholeField {
            guard SelectedTextReader.stringAttribute(element, kAXSelectedTextAttribute) == text else {
                throw SelectedTextFailure.targetChanged
            }
            let currentRange = SelectedTextReader.selectedRange(element)
            guard currentRange?.location == selection?.location, currentRange?.length == selection?.length else {
                throw SelectedTextFailure.targetChanged
            }
        }
        var settable: DarwinBoolean = false
        let attribute = wholeField ? kAXValueAttribute : kAXSelectedTextAttribute
        if AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success, settable.boolValue {
            guard AXUIElementSetAttributeValue(element, attribute as CFString, replacement as CFString) == .success else {
                throw SelectedTextFailure.cannotReplace
            }
            return
        }
        guard !wholeField, let original = fullText, let range = selection,
              range.location >= 0, range.length >= 0,
              range.location + range.length <= (original as NSString).length,
              AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
              settable.boolValue else { throw SelectedTextFailure.cannotReplace }
        let updated = (original as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: replacement)
        guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updated as CFString) == .success else {
            throw SelectedTextFailure.cannotReplace
        }
    }
}

enum SelectedTextFailure: LocalizedError {
    case permissionRequired, noSelection, targetChanged, cannotReplace
    var errorDescription: String? {
        switch self {
        case .permissionRequired: return "取词需要辅助功能权限。请在系统设置中允许 DAX 读取所选文字，或复制文字后从剪贴板翻译。"
        case .noSelection: return "未读取到所选文字。可以重新选择，或复制文字后从剪贴板翻译。"
        case .targetChanged: return "原输入框或选区已经变化，请重新取词后再替换。"
        case .cannotReplace: return "此应用不支持直接替换文字，可以复制译文后粘贴。"
        }
    }
}
