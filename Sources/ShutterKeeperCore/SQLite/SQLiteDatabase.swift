import Foundation
import SQLite3

public enum SQLValue: Equatable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var intValue: Int? {
        switch self {
        case .integer(let value): return Int(value)
        case .real(let value): return Int(value)
        case .text(let value): return Int(value)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .real(let value): return value
        case .text(let value): return Double(value)
        default: return nil
        }
    }

    public var stringValue: String? {
        switch self {
        case .text(let value): return value
        case .integer(let value): return String(value)
        case .real(let value): return String(value)
        case .blob(let data): return String(data: data, encoding: .utf8)
        case .null: return nil
        }
    }
}

public struct SQLiteError: Error, LocalizedError {
    public let message: String
    public let code: Int32
    public let sql: String?

    public var errorDescription: String? {
        if let sql { return "SQLite 错误：\(message)（\(sql)）" }
        return "SQLite 错误：\(message)"
    }
}

/// 系统自带 SQLite 的极薄封装。没有第三方依赖。
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    public let path: String

    /// - Parameters:
    ///   - readOnly: 只读打开（用于读取 Lightroom 目录这类别人的数据库）。
    ///   - immutable: 以 SQLite 的 immutable 方式打开，完全不加锁。仅在只读打开失败时作为兜底。
    public init(path: String, readOnly: Bool = false, immutable: Bool = false) throws {
        self.path = path
        if immutable {
            var handle: OpaquePointer?
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2("file:\(encoded)?immutable=1", &handle, flags, nil) == SQLITE_OK else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
                sqlite3_close(handle)
                throw SQLiteError(message: message, code: SQLITE_CANTOPEN, sql: nil)
            }
            self.handle = handle
            return
        }
        var flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        flags |= SQLITE_OPEN_FULLMUTEX
        var status = sqlite3_open_v2(path, &handle, flags, nil)
        if status != SQLITE_OK, readOnly {
            // WAL 模式的数据库在缺少 -shm 文件时无法用只读方式打开，
            // 这时退回 SQLite 的 immutable 方式（只读取，不建锁文件）。
            sqlite3_close(handle)
            handle = nil
            if let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                status = sqlite3_open_v2(
                    "file:\(encoded)?immutable=1",
                    &handle,
                    SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
                    nil
                )
            }
        }
        guard status == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            sqlite3_close(handle)
            handle = nil
            throw SQLiteError(message: message, code: SQLITE_CANTOPEN, sql: nil)
        }
        if !readOnly {
            sqlite3_busy_timeout(handle, 5000)
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA foreign_keys = ON;")
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    public var lastInsertedRowID: Int64 {
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "执行失败"
            if let errorMessage { sqlite3_free(errorMessage) }
            throw SQLiteError(message: message, code: SQLITE_ERROR, sql: sql)
        }
    }

    @discardableResult
    public func run(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError(message: currentErrorMessage, code: result, sql: sql)
        }
        return Int(sqlite3_changes(handle))
    }

    public func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [[String: SQLValue]] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: SQLValue]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw SQLiteError(message: currentErrorMessage, code: result, sql: sql)
            }
            var row: [String: SQLValue] = [:]
            let columnCount = sqlite3_column_count(statement)
            for index in 0..<columnCount {
                let name = String(cString: sqlite3_column_name(statement, index))
                row[name] = value(of: statement, column: index)
            }
            rows.append(row)
        }
        return rows
    }

    public func queryOne(_ sql: String, _ parameters: [SQLValue] = []) throws -> [String: SQLValue]? {
        try query(sql, parameters).first
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - 内部

    private var currentErrorMessage: String {
        guard let handle else { return "数据库已关闭" }
        return String(cString: sqlite3_errmsg(handle))
    }

    private func prepare(_ sql: String, _ parameters: [SQLValue]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteError(message: currentErrorMessage, code: SQLITE_ERROR, sql: sql)
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch parameter {
            case .null:
                sqlite3_bind_null(statement, index)
            case .integer(let value):
                sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                sqlite3_bind_double(statement, index, value)
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, SQLiteDatabase.transient)
            case .blob(let data):
                data.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), SQLiteDatabase.transient)
                }
            }
        }
        return statement
    }

    private func value(of statement: OpaquePointer?, column: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            if let text = sqlite3_column_text(statement, column) {
                return .text(String(cString: text))
            }
            return .null
        case SQLITE_BLOB:
            if let blob = sqlite3_column_blob(statement, column) {
                let length = Int(sqlite3_column_bytes(statement, column))
                return .blob(Data(bytes: blob, count: length))
            }
            return .null
        default:
            return .null
        }
    }
}
