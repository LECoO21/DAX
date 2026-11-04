import Foundation
import SQLite3

private enum Failure: Error { case assertion(String) }
private func require(_ value: Bool, _ message: String) throws { if !value { throw Failure.assertion(message) } }

@main
private struct StorageChecks {
    @MainActor
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dax-history-check-" + UUID().uuidString)
        var store: HistoryStore? = try HistoryStore(root: root)
        defer { store = nil; try? FileManager.default.removeItem(at: root) }
        let serviceID = UUID()
        let result = ServiceResult(id: serviceID, name: "Mock", state: .success, output: TranslationOutput(text: "中文译文"))
        var record = HistoryRecord(createdAt: Date(timeIntervalSince1970: 1_700_000_000), text: "100% _ test\u{0}tail", source: "en", target: "zh-Hans", results: [result])
        try store!.upsert(record)
        try require(try store!.list().first?.text == record.text, "Text including NUL roundtrip")
        try require(try store!.list(search: "%").count == 1, "Percent literal search")
        try require(try store!.list(search: "中文译文").count == 1, "Search translated content")
        try store!.setFavorite(id: record.id, value: true)
        record.results = []
        try store!.upsert(record)
        try require(try store!.list().first?.favorite == true, "Asynchronous upsert preserves favorite")
        try store!.setFavorite(id: record.id, value: false)
        record.favorite = true
        try store!.upsert(record)
        try require(try store!.list().first?.favorite == false, "Asynchronous upsert preserves explicit unfavorite")

        let originalText = record.text
        record.text = "Old import must not replace local content"
        let archive = try store!.exportJSON([record, record])
        try require(try store!.importJSON(archive) == 0, "Duplicate import count")
        try require(try store!.list().first?.text == originalText, "Duplicate import preserves existing content")
        try require(try store!.list().first?.favorite == true, "Imported favorite merges into existing record")

        var another = HistoryRecord(text: "=SUM(1,2)\nquoted \"text\"", source: "en", target: "zh-Hans", results: [result])
        let imported = try store!.exportJSON([another])
        try require(try store!.importJSON(imported) == 1, "New import")
        let csv = String(data: store!.exportCSV([another]), encoding: .utf8)!
        try require(csv.contains("\"'=SUM(1,2)"), "CSV formula protection")
        try require(csv.contains("\"\"text\"\""), "CSV quoted string encoding")

        var invalidObject = try JSONSerialization.jsonObject(with: imported) as! [String: Any]
        var invalidRecords = invalidObject["records"] as! [[String: Any]]
        invalidRecords[0]["id"] = UUID().uuidString
        invalidRecords[0]["text"] = "  "
        invalidObject["records"] = invalidRecords
        let invalidData = try JSONSerialization.data(withJSONObject: invalidObject)
        do { _ = try store!.importJSON(invalidData); throw Failure.assertion("Invalid record accepted") }
        catch is Failure { throw Failure.assertion("Invalid record accepted") }
        catch {}
        try require(try store!.list().count == 2, "Invalid import leaves existing data untouched")

        try store!.clear()
        try require(try store!.list().count == 1 && store!.list().first?.favorite == true, "Clear preserves favorite")
        try store!.clear(includeFavorites: true)
        try require(try store!.list().isEmpty, "Clear all")
        for index in 0..<4 {
            another = HistoryRecord(createdAt: Date(timeIntervalSince1970: Double(index)), text: "Record \(index)", source: "en", target: "zh-Hans", results: [], favorite: index == 0)
            try store!.upsert(another)
        }
        try store!.prune(maxCount: 2)
        let pruned = try store!.list()
        try require(pruned.count == 2 && pruned.map(\.text).contains("Record 0") && pruned.map(\.text).contains("Record 3"), "Prune preserves favorite and newest record")
        try require(try store!.list(limit: 1, offset: 1).count == 1, "Pagination")
        do { _ = try store!.list(offset: -1); throw Failure.assertion("Invalid pagination accepted") }
        catch is Failure { throw Failure.assertion("Invalid pagination accepted") }
        catch {}
        store = nil
        store = try HistoryStore(root: root)
        try require(try store!.list().count == 2, "Restart persistence")
        try store!.delete(id: pruned[0].id)
        try require(try store!.list().count == 1, "Individual deletion")
        print("PASS: history persistence, search, favorite consistency, import deduplication, atomic validation, CSV safety, pruning and deletion")
    }
}
