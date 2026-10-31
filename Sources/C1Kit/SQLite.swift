import CSQLite
import Foundation

enum SQLValue: Equatable {
    case null, int(Int64), double(Double), text(String)

    var int: Int64? { if case .int(let value) = self { return value }; return nil }
    var text: String? { if case .text(let value) = self { return value }; return nil }
}

typealias SQLRow = [String: SQLValue]

/// A read-only SQLite connection. Capture One keeps writing the file, so it is opened with `mode=ro`.
final class SQLiteConnection {
    private var handle: OpaquePointer?
    let path: String

    init(readOnly path: String) throws {
        self.path = path
        guard FileManager.default.fileExists(atPath: path) else {
            throw C1Failure(.database, "No Capture One database at \(path).")
        }
        var components = URLComponents()
        components.scheme = "file"
        components.path = path
        components.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        let uri = components.string!
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw C1Failure(.database, "Cannot open \(path) read-only: \(message).")
        }
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit { sqlite3_close(handle) }

    func rows(_ sql: String, _ bindings: [SQLValue] = []) throws -> [SQLRow] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { throw failure("prepare") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .null: sqlite3_bind_null(statement, position)
            case .int(let value): sqlite3_bind_int64(statement, position, value)
            case .double(let value): sqlite3_bind_double(statement, position, value)
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, transient)
            }
        }
        var output: [SQLRow] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw failure("step") }
            var row: SQLRow = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                default: row[name] = .null
                }
            }
            output.append(row)
        }
        return output
    }

    private func failure(_ stage: String) -> C1Failure {
        C1Failure(.database, "SQLite \(stage) failed on \(path): \(String(cString: sqlite3_errmsg(handle))).")
    }
}
