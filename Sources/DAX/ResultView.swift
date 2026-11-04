import SwiftUI
import AppKit

struct ResultView: View {
    @ObservedObject var model: AppModel
    var onResize: (CGFloat) -> Void
    var openSettings: () -> Void
    var openHistory: () -> Void
    @LocalState private var contentHeight: CGFloat = 320
    @LocalState private var inputVisible = true
    private var width: CGFloat { model.panelWidth }
    private var maxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) * model.preferences.maxHeightFraction }

    var body: some View {
        ScrollView {
            VStack(spacing: 9) {
                toolbar
                if inputVisible { inputCard }
                if model.mode == .translate && model.preferences.showLanguageBar { languages }
                if model.mode == .translate {
                    if model.results.isEmpty {
                        Button("选择翻译服务", action: openSettings).padding(12)
                    }
                    ForEach(model.results) { result in
                        ResultCard(model: model, result: result, openSettings: openSettings)
                    }
                }
                if model.isError {
                    Text(model.status).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
                guard height > 0 else { return }
                if abs(contentHeight - height) > 1 { contentHeight = height }
                onResize(min(maxHeight, max(150, height)))
            }
        }
        .frame(width: width, height: min(maxHeight, max(150, contentHeight)))
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.inputVisibilityOverride) { _, value in inputVisible = value ?? model.preferences.showInput }
        .onChange(of: model.preferences.showInput, initial: true) { _, value in inputVisible = value }
    }
    private var toolbar: some View {
        HStack(spacing: 15) {
            icon(model.pinned ? "pin.fill" : "pin", "置顶") { model.pinned.toggle(); model.onPreferencesChanged?() }
                .foregroundStyle(model.pinned ? Color.accentColor : Color.secondary)
            Spacer()
            if model.preferences.showFavoriteButton { icon(model.favorite ? "star.fill" : "star", "收藏") { model.toggleFavorite() }.disabled(model.input.isEmpty) }
            icon(inputVisible ? "rectangle.compress.vertical" : "rectangle.expand.vertical", "显示或隐藏原文") { inputVisible.toggle() }
            if model.preferences.showCaptureButton { icon("scissors", "截图翻译") { model.perform(.captureTranslate) } }
            if model.preferences.showClipboardButton { icon("doc.on.clipboard", "剪贴板翻译") { model.perform(.clipboardTranslate) } }
            if model.preferences.showHistoryButton { icon("clock", "历史记录", action: openHistory) }
            icon("slider.horizontal.3", "设置", action: openSettings)
            icon("xmark", "关闭") { NSApp.keyWindow?.performClose(nil) }
        }.font(.system(size: 16)).padding(.horizontal, 6).padding(.vertical, 5)
    }
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack(alignment: .topLeading) {
                InputTextEditor(text: Binding(get: { model.input }, set: { model.editInput($0) }), fontSize: model.preferences.fontSize) {
                    model.mode = .translate
                    model.submit()
                }
                if model.input.isEmpty { Text("输入文字，或使用快捷键截图").foregroundStyle(.tertiary).padding(.top, 5).padding(.leading, 5).allowsHitTesting(false) }
            }
            .frame(height: textHeight(model.input, width: width - 60, fontSize: model.preferences.fontSize, cap: model.preferences.inputMaxHeight))
            HStack(spacing: 14) {
                icon("speaker.wave.2", "朗读原文") { model.speak(model.input, language: model.actualSource) }.disabled(model.input.isEmpty)
                icon("doc.on.doc", "复制原文") { model.copy(model.input) }.disabled(model.input.isEmpty)
                Text("识别为 \(model.detectedName)").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 9).padding(.vertical, 5).background(Color.secondary.opacity(0.09), in: Capsule())
                Spacer()
                if model.mode == .ocr {
                    icon("plus.viewfinder", "继续截图并追加文字") { model.perform(.continuousOCR) }
                    Button("翻译") { model.mode = .translate; model.submit(origin: "ocr") }.controlSize(.small)
                } else {
                    icon("arrow.turn.down.left", "翻译 ↩ · Shift+↩ 换行") { model.submit() }.disabled(model.input.isEmpty)
                }
            }.font(.system(size: 15))
        }.padding(11).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }
    private var languages: some View {
        HStack {
            languageMenu(model.source, choices: LanguageChoice.sources) { model.source = $0; model.languageChanged() }
            Spacer()
            icon("arrow.left.arrow.right", "交换语言") { model.swapLanguages() }
            Spacer()
            languageMenu(model.target, choices: LanguageChoice.targets) { model.target = $0; model.languageChanged() }
        }.padding(.horizontal, 14).padding(.vertical, 9)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    private func languageMenu(_ code: String, choices: [LanguageChoice], select: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(choices.prefix(LanguageChoice.common.count)) { choice in Button(choice.name) { select(choice.id) } }
            Divider()
            Menu("更多语言") {
                ForEach(choices.dropFirst(LanguageChoice.common.count)) { choice in Button(choice.name) { select(choice.id) } }
            }
        } label: {
            HStack(spacing: 5) { Text(choices.first(where: { $0.id == code })?.name ?? code); Image(systemName: "chevron.down").font(.caption2) }
                .font(.system(size: 14, weight: .medium))
        }.menuStyle(.borderlessButton).fixedSize()
    }
}

struct ResultCard: View {
    @ObservedObject var model: AppModel
    let result: ServiceResult
    var openSettings: () -> Void
    @LocalState private var expanded = true
    @LocalState private var richHeight: CGFloat = 40
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "character.bubble.fill").foregroundStyle(Color.accentColor)
                Text(result.name).font(.system(size: 14, weight: .semibold))
                Spacer()
                if result.state == .running || result.state == .pending { ProgressView().controlSize(.small) }
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right") }.buttonStyle(.borderless)
            }
            if expanded {
                if let output = result.output, !output.text.isEmpty || output.html != nil {
                    if model.preferences.renderMarkdown && (output.markdown || output.html != nil) {
                        RichResultView(output: output, fontSize: model.preferences.fontSize, pluginStore: model.pluginStore) { richHeight = $0 }.frame(height: min(440, richHeight))
                    } else {
                        ScrollView { Text(output.text).font(.system(size: model.preferences.fontSize)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(height: textHeight(output.text, width: model.panelWidth - 50, fontSize: model.preferences.fontSize, cap: 300))
                    }
                    HStack(spacing: 15) {
                        icon("speaker.wave.2", "朗读译文") { model.speak(output.text, language: model.actualTarget) }
                        icon("doc.on.doc", "复制译文") { model.copy(output.text) }
                        if model.canReplaceSelection { icon("arrow.right.square", "使用译文替换原文") { model.replaceSelection(output.text) } }
                        if model.preferences.showNamingCopies {
                            Menu {
                                ForEach(CopyStyle.allCases, id: \.self) { style in Button(style.rawValue) { model.copy(style.apply(output.text)) } }
                            } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }.menuStyle(.borderlessButton).fixedSize()
                        }
                        Spacer()
                        icon("arrow.clockwise", "重试此服务") { model.retry(result.id) }
                    }.font(.system(size: 15))
                } else if result.state == .idle {
                    Button("使用此服务翻译") { model.retry(result.id) }.controlSize(.small)
                } else if result.state == .failed {
                    Text(result.error ?? "翻译失败").font(.system(size: 13)).foregroundStyle(.orange).textSelection(.enabled)
                    HStack { Button("重试") { model.retry(result.id) }; Button("配置服务", action: openSettings) }.controlSize(.small)
                } else if result.state == .cancelled { Text("已取消").foregroundStyle(.secondary) }
                else { Text("正在翻译…").font(.system(size: 14)).foregroundStyle(.secondary) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
    }
}

func icon(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(minWidth: 18, minHeight: 22) }.buttonStyle(.borderless).help(help)
}
func textHeight(_ text: String, width: CGFloat, fontSize: Double, cap: Double) -> CGFloat {
    let value = text.isEmpty ? "输入文字" : text
    let bounds = (value as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
    return min(CGFloat(cap), max(40, ceil(bounds.height) + 13))
}
enum CopyStyle: String, CaseIterable {
    case camel = "驼峰命名", pascal = "大驼峰命名", snake = "蛇形命名", kebab = "短横线命名", macro = "宏定义命名"
    func apply(_ text: String) -> String {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.map { $0.lowercased() }
        switch self {
        case .camel: return (words.first ?? "") + words.dropFirst().map(\.capitalized).joined()
        case .pascal: return words.map(\.capitalized).joined()
        case .snake: return words.joined(separator: "_")
        case .kebab: return words.joined(separator: "-")
        case .macro: return words.joined(separator: "_").uppercased()
        }
    }
}
