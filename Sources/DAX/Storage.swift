import Foundation
import SQLite3

private enum HistoryError: LocalizedError {
    case database(String, Int32)
    case unsupportedVersion
    case invalidArchive
    case invalidRecord
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .database(let operation, let code): return "历史记录\(operation)失败（SQLite \(code)）。请检查储存位置和可用空间。"
        case .unsupportedVersion: return "历史数据库版本比当前应用更新，请使用较新的 DAX 打开。"
        case .invalidArchive: return "历史文件格式不正确或版本不受支持，请选择 DAX 导出的 JSON 文件。"
        case .invalidRecord: return "历史文件包含无效记录，导入未应用。"
        case .invalidRange: return "历史记录的分页或保留数量无效。"
        }
    }
}

private struct HistoryArchive: Codable {
    var schemaVersion = 1
    var records: [HistoryRecord]
}

/// All database access stays on the application's main actor. Writes are transactional.
@MainActor
final class HistoryStore {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("history.sqlite3")
        let existed = FileManager.default.fileExists(atPath: file.path)
        var connection: OpaquePointer?
        let status = sqlite3_open_v2(file.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let connection else {
            if let connection { sqlite3_close_v2(connection) }
            throw HistoryError.database("打开", status)
        }
        database = connection
        sqlite3_busy_timeout(connection, 3000)
        do {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            let versionStatement = try prepare("PRAGMA user_version")
            let versionStatus = sqlite3_step(versionStatement)
            let version = versionStatus == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : -1
            sqlite3_finalize(versionStatement)
            guard version >= 0 else { throw HistoryError.database("读取版本", versionStatus) }
            guard version <= 1 else { throw HistoryError.unsupportedVersion }
            try execute("""
                CREATE TABLE IF NOT EXISTS history (
                    id TEXT PRIMARY KEY NOT NULL,
                    created_at REAL NOT NULL,
                    text TEXT NOT NULL,
                    source TEXT NOT NULL,
                    target TEXT NOT NULL,
                    results BLOB NOT NULL,
                    favorite INTEGER NOT NULL DEFAULT 0 CHECK(favorite IN (0,1)),
                    origin TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS history_date ON history(created_at DESC);
                CREATE INDEX IF NOT EXISTS history_favorites ON history(favorite, created_at DESC);
                PRAGMA user_version=1;
                """)
            if !existed { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        } catch {
            sqlite3_close_v2(connection)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close_v2(database) } }

    /// Query updates preserve favorites. Explicit removal uses setFavorite(id:value:).
    func upsert(_ record: HistoryRecord) throws {
        try validate(record)
        let statement = try prepare("""
            INSERT INTO history (id,created_at,text,source,target,results,favorite,origin)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                created_at=excluded.created_at,
                text=excluded.text,
                source=excluded.source,
                target=excluded.target,
                results=excluded.results,
                favorite=history.favorite,
                origin=excluded.origin
            """)
        defer { sqlite3_finalize(statement) }
        try bind(record, to: statement)
        try finish(statement)
    }

    func list(search: String = "", favoritesOnly: Bool = false, limit: Int = 200, offset: Int = 0) throws -> [HistoryRecord] {
        guard limit >= 0, offset >= 0 else { throw HistoryError.invalidRange }
        let statement = try prepare("""
            SELECT id,created_at,text,source,target,results,favorite,origin FROM history
            WHERE (?=0 OR favorite=1)
              AND (?='' OR text LIKE ? ESCAPE char(92) OR CAST(results AS TEXT) LIKE ? ESCAPE char(92))
            ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, favoritesOnly ? 1 : 0)
        try bind(search, at: 2, to: statement)
        let escaped = search.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        try bind("%" + escaped + "%", at: 3, to: statement)
        try bind("%" + escaped + "%", at: 4, to: statement)
        sqlite3_bind_int64(statement, 5, sqlite3_int64(limit))
        sqlite3_bind_int64(statement, 6, sqlite3_int64(offset))
        var records: [HistoryRecord] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return records }
            guard status == SQLITE_ROW else { throw HistoryError.database("读取", status) }
            guard let id = UUID(uuidString: string(statement, column: 0)) else { throw HistoryError.invalidRecord }
            let count = Int(sqlite3_column_bytes(statement, 5))
            guard let bytes = sqlite3_column_blob(statement, 5), count > 0 else { throw HistoryError.invalidRecord }
            let results = try decoder.decode([ServiceResult].self, from: Data(bytes: bytes, count: count))
            records.append(HistoryRecord(id: id, createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                         text: string(statement, column: 2), source: string(statement, column: 3),
                                         target: string(statement, column: 4), results: results,
                                         favorite: sqlite3_column_int(statement, 6) != 0, origin: string(statement, column: 7)))
        }
    }

    func delete(id: UUID) throws {
        let statement = try prepare("DELETE FROM history WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        try finish(statement)
    }

    func setFavorite(id: UUID, value: Bool) throws {
        let statement = try prepare("UPDATE history SET favorite=? WHERE id=?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, value ? 1 : 0)
        try bind(id.uuidString, at: 2, to: statement)
        try finish(statement)
    }

    func clear(includeFavorites: Bool = false) throws {
        try execute(includeFavorites ? "DELETE FROM history" : "DELETE FROM history WHERE favorite=0")
    }

    /// Keeps newest records within the count, while always preserving favorites.
    func prune(maxCount: Int) throws {
        guard maxCount >= 0 else { throw HistoryError.invalidRange }
        try transaction {
            let countStatement = try prepare("SELECT COUNT(*) FROM history WHERE favorite=1")
            let status = sqlite3_step(countStatement)
            guard status == SQLITE_ROW else {
                sqlite3_finalize(countStatement)
                throw HistoryError.database("读取", status)
            }
            let favorites = Int(sqlite3_column_int64(countStatement, 0))
            sqlite3_finalize(countStatement)
            let keep = max(0, maxCount - favorites)
            let statement = try prepare("""
                DELETE FROM history WHERE id IN (
                    SELECT id FROM history WHERE favorite=0
                    ORDER BY created_at DESC,id DESC LIMIT -1 OFFSET ?
                )
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, sqlite3_int64(keep))
            try finish(statement)
        }
    }

    func exportJSON(_ records: [HistoryRecord]) throws -> Data {
        for record in records { try validate(record) }
        let exportEncoder = JSONEncoder()
        exportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        exportEncoder.dateEncodingStrategy = .iso8601
        return try exportEncoder.encode(HistoryArchive(records: records))
    }

    /// One CSV row per service result. Text cells are protected against spreadsheet formulas.
    func exportCSV(_ records: [HistoryRecord]) -> Data {
        let header = ["查询ID", "查询时间", "原文", "源语言", "目标语言", "收藏", "来源", "服务", "状态", "译文", "错误"]
        var rows = [header]
        let formatter = ISO8601DateFormatter()
        for record in records {
            let base = [record.id.uuidString, formatter.string(from: record.createdAt), record.text,
                        record.source, record.target, record.favorite ? "是" : "否", record.origin]
            if record.results.isEmpty {
                rows.append(base + ["", "", "", ""])
            } else {
                for result in record.results {
                    rows.append(base + [result.name, result.state.rawValue, result.output?.text ?? "", result.error ?? ""])
                }
            }
        }
        let output = rows.map { $0.map(Self.csvCell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
        return Data(("\u{FEFF}" + output).utf8)
    }

    /// Returns the number of new records. Existing content is kept and favorites are merged.
    @discardableResult
    func importJSON(_ data: Data) throws -> Int {
        guard data.count <= 100 * 1024 * 1024 else { throw HistoryError.invalidArchive }
        let importDecoder = JSONDecoder()
        importDecoder.dateDecodingStrategy = .iso8601
        guard let archive = try? importDecoder.decode(HistoryArchive.self, from: data), archive.schemaVersion == 1,
              archive.records.count <= 100_000 else { throw HistoryError.invalidArchive }
        var records: [UUID: HistoryRecord] = [:]
        for var record in archive.records {
            try validate(record)
            record.favorite = record.favorite || (records[record.id]?.favorite ?? false)
            records[record.id] = record
        }
        var added = 0
        try transaction {
            let statement = try prepare("""
                INSERT OR IGNORE INTO history(id,created_at,text,source,target,results,favorite,origin)
                VALUES (?,?,?,?,?,?,?,?)
                """)
            defer { sqlite3_finalize(statement) }
            for record in records.values {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                try bind(record, to: statement)
                try finish(statement)
                added += Int(sqlite3_changes(database))
                if record.favorite { try setFavorite(id: record.id, value: true) }
            }
        }
        return added
    }

    private func validate(_ record: HistoryRecord) throws {
        guard record.createdAt.timeIntervalSince1970.isFinite,
              !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !record.source.isEmpty, record.source.count <= 32,
              !record.target.isEmpty, record.target.count <= 32,
              !record.origin.isEmpty,
              record.results.allSatisfy({ !$0.name.isEmpty }) else { throw HistoryError.invalidRecord }
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw HistoryError.database("打开", SQLITE_MISUSE) }
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else { throw HistoryError.database("准备操作", status) }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard let database else { throw HistoryError.database("打开", SQLITE_MISUSE) }
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw HistoryError.database("写入", status) }
    }
    private func finish(_ statement: OpaquePointer) throws {
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else { throw HistoryError.database("写入", status) }
    }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        guard value.utf8.count <= Int(Int32.max) else { throw HistoryError.invalidRecord }
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, Int32(value.utf8.count), Self.transient)
        }
        guard status == SQLITE_OK else { throw HistoryError.database("准备数据", status) }
    }
    private func bind(_ record: HistoryRecord, to statement: OpaquePointer) throws {
        try bind(record.id.uuidString, at: 1, to: statement)
        sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
        try bind(record.text, at: 3, to: statement)
        try bind(record.source, at: 4, to: statement)
        try bind(record.target, at: 5, to: statement)
        let resultData = try encoder.encode(record.results)
        let status = resultData.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        guard status == SQLITE_OK else { throw HistoryError.database("准备结果", status) }
        sqlite3_bind_int(statement, 7, record.favorite ? 1 : 0)
        try bind(record.origin, at: 8, to: statement)
    }
    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        return String(decoding: bytes, as: UTF8.self)
    }
    private static func csvCell(_ input: String) -> String {
        let first = input.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = first.map { "=+-@".contains($0) } == true ? "'" + input : input
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
