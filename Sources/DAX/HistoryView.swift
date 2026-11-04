import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @LocalState private var search = ""
    @LocalState private var favoritesOnly = false
    @LocalState private var limit = 200
    @LocalState private var issue = ""
    @LocalState private var confirmClear = false
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                TextField("搜索原文", text: $search).textFieldStyle(.roundedBorder)
                Toggle("仅收藏", isOn: $favoritesOnly).toggleStyle(.checkbox)
                Menu("导入导出") {
                    Button("导出 JSON") { export(csv: false) }
                    Button("导出 CSV") { export(csv: true) }
                    Button("导入 JSON") { importRecords() }
                    Divider()
                    Button("清空非收藏历史", role: .destructive) { confirmClear = true }
                }.fixedSize()
            }
            List {
                ForEach(model.historyRows) { record in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            Text("\(LanguageChoice.name(record.source)) → \(LanguageChoice.name(record.target))").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { favorite(record) } label: { Image(systemName: record.favorite ? "star.fill" : "star") }.buttonStyle(.borderless)
                            Button { model.loadHistory(record) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.borderless).help("查看结果")
                            Button { remove(record) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                        Text(record.text).lineLimit(3).textSelection(.enabled)
                        if let translation = record.results.first(where: { $0.state == .success })?.output?.text {
                            Text(translation).lineLimit(2).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
                if model.historyRows.count >= limit { Button("加载更多") { limit += 200; reload() } }
            }
            if !issue.isEmpty { Text(issue).foregroundStyle(.orange).font(.caption) }
        }.padding(16).frame(minWidth: 650, minHeight: 470)
        .onAppear { reload() }
        .onChange(of: search) { _, _ in reload() }
        .onChange(of: favoritesOnly) { _, _ in reload() }
        .confirmationDialog("清空所有未收藏的历史记录？", isPresented: $confirmClear) {
            Button("清空历史", role: .destructive) { do { try model.clearHistory(); reload() } catch { issue = error.localizedDescription } }
        }
    }
    private func reload() {
        do { model.historyRows = try model.history.list(search: search, favoritesOnly: favoritesOnly, limit: limit); issue = "" }
        catch { issue = error.localizedDescription }
    }
    private func favorite(_ record: HistoryRecord) {
        do { try model.setHistoryFavorite(record, value: !record.favorite); reload() } catch { issue = error.localizedDescription }
    }
    private func remove(_ record: HistoryRecord) {
        do { try model.deleteHistory(record); reload() } catch { issue = error.localizedDescription }
    }
    private func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = csv ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = csv ? "DAX历史.csv" : "DAX历史.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let rows = try model.history.list(search: search, favoritesOnly: favoritesOnly, limit: Int.max)
            let data = try csv ? model.history.exportCSV(rows) : model.history.exportJSON(rows)
            try data.write(to: url, options: .atomic)
        } catch { issue = error.localizedDescription }
    }
    private func importRecords() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let count = try model.history.importJSON(Data(contentsOf: url)); reload(); issue = "已导入 \(count) 条记录" }
        catch { issue = error.localizedDescription }
    }
}
