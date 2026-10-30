import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case openFailed(String)
    case statementFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .openFailed(let message): return "数据库打开失败：\(message)"
        case .statementFailed(let message): return "数据库语句失败：\(message)"
        case .bindFailed(let message): return "数据库参数失败：\(message)"
        case .stepFailed(let message): return "数据库执行失败：\(message)"
        case .encodingFailed: return "本地草稿编码失败。"
        }
    }
}

final class Database {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let databaseURL: URL

    init() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkshopLedger", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let databaseURL = support.appendingPathComponent("workshop-ledger.sqlite3")
        self.databaseURL = databaseURL

        if sqlite3_open(databaseURL.path, &db) != SQLITE_OK {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            if let db { sqlite3_close(db) }
            self.db = nil
            throw DatabaseError.openFailed(message)
        }

        sqlite3_busy_timeout(db, 5000)
        try migrate()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func migrate() throws {
        try execute("PRAGMA foreign_keys = ON;")
        try execute("""
            CREATE TABLE IF NOT EXISTS customers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                created_at REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS employees (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                created_at REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS bills (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bill_date TEXT NOT NULL UNIQUE,
                submitted_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS bill_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bill_id INTEGER NOT NULL,
                customer TEXT NOT NULL,
                employee TEXT NOT NULL,
                model TEXT NOT NULL,
                quantity INTEGER NOT NULL,
                color_count INTEGER NOT NULL,
                FOREIGN KEY (bill_id) REFERENCES bills(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_bill_items_bill_id ON bill_items(bill_id);
            CREATE INDEX IF NOT EXISTS idx_bills_date ON bills(bill_date DESC);
            CREATE TABLE IF NOT EXISTS drafts (
                bill_date TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """)

        // Keeps databases created by earlier prototype builds compatible.
        try? execute("ALTER TABLE customers ADD COLUMN created_at REAL NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE customers ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE employees ADD COLUMN created_at REAL NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE employees ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")
        try execute("""
            UPDATE customers
            SET created_at = CASE WHEN created_at = 0 THEN strftime('%s','now') ELSE created_at END,
                updated_at = CASE WHEN updated_at = 0 THEN strftime('%s','now') ELSE updated_at END;
            UPDATE employees
            SET created_at = CASE WHEN created_at = 0 THEN strftime('%s','now') ELSE created_at END,
                updated_at = CASE WHEN updated_at = 0 THEN strftime('%s','now') ELSE updated_at END;
            """)
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw DatabaseError.openFailed("数据库未打开") }
        var errorMessage: UnsafeMutablePointer<Int8>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.flatMap { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errorMessage)
            throw DatabaseError.statementFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw DatabaseError.openFailed("数据库未打开") }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            let message = String(cString: sqlite3_errmsg(db))
            throw DatabaseError.statementFailed(message)
        }
        guard let statement else { throw DatabaseError.statementFailed("无法创建 SQLite statement") }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            let message = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
            throw DatabaseError.stepFailed(message)
        }
    }

    private func bindText(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, transient)
        }
        guard result == SQLITE_OK else {
            throw DatabaseError.bindFailed("文本参数 \(index)")
        }
    }

    private func text(column: Int32, statement: OpaquePointer) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return value.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
    }

    private var lastInsertID: Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Directory

    func loadCustomers() throws -> [Customer] {
        let statement = try prepare("SELECT id, name, created_at, updated_at FROM customers ORDER BY name COLLATE NOCASE;")
        defer { sqlite3_finalize(statement) }
        var result: [Customer] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                Customer(
                    id: sqlite3_column_int64(statement, 0),
                    name: text(column: 1, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                )
            )
        }
        return result
    }

    func addCustomer(name: String) throws -> Customer {
        let statement = try prepare("INSERT INTO customers(name, created_at, updated_at) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        try bindText(name, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_bind_double(statement, 3, now)
        try stepDone(statement)
        return Customer(id: lastInsertID, name: name, createdAt: Date(timeIntervalSince1970: now), updatedAt: Date(timeIntervalSince1970: now))
    }

    func updateCustomer(id: Int64, name: String) throws {
        let statement = try prepare("UPDATE customers SET name = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(name, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        try stepDone(statement)
    }

    func deleteCustomer(id: Int64) throws {
        let statement = try prepare("DELETE FROM customers WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        try stepDone(statement)
    }

    func loadEmployees() throws -> [Employee] {
        let statement = try prepare("SELECT id, name, created_at, updated_at FROM employees ORDER BY name COLLATE NOCASE;")
        defer { sqlite3_finalize(statement) }
        var result: [Employee] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                Employee(
                    id: sqlite3_column_int64(statement, 0),
                    name: text(column: 1, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                )
            )
        }
        return result
    }

    func addEmployee(name: String) throws -> Employee {
        let statement = try prepare("INSERT INTO employees(name, created_at, updated_at) VALUES (?, ?, ?);")
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        try bindText(name, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, now)
        sqlite3_bind_double(statement, 3, now)
        try stepDone(statement)
        return Employee(id: lastInsertID, name: name, createdAt: Date(timeIntervalSince1970: now), updatedAt: Date(timeIntervalSince1970: now))
    }

    func updateEmployee(id: Int64, name: String) throws {
        let statement = try prepare("UPDATE employees SET name = ?, updated_at = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(name, at: 1, in: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 3, id)
        try stepDone(statement)
    }

    func deleteEmployee(id: Int64) throws {
        let statement = try prepare("DELETE FROM employees WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        try stepDone(statement)
    }

    // MARK: - Bills

    func loadBills() throws -> [Bill] {
        let statement = try prepare("SELECT id, bill_date, submitted_at FROM bills ORDER BY bill_date DESC;")
        defer { sqlite3_finalize(statement) }
        var bills: [Bill] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let billID = sqlite3_column_int64(statement, 0)
            let dateString = text(column: 1, statement: statement)
            guard let date = DateKey.date(from: dateString) else { continue }
            let submittedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            let items = try loadBillItems(billID: billID)
            bills.append(Bill(id: billID, date: date, submittedAt: submittedAt, items: items))
        }
        return bills
    }

    private func loadBillItems(billID: Int64) throws -> [BillItem] {
        let statement = try prepare("""
            SELECT id, bill_id, customer, employee, model, quantity, color_count
            FROM bill_items WHERE bill_id = ? ORDER BY id ASC;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, billID)
        var result: [BillItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                BillItem(
                    id: sqlite3_column_int64(statement, 0),
                    billID: sqlite3_column_int64(statement, 1),
                    customer: text(column: 2, statement: statement),
                    employee: text(column: 3, statement: statement),
                    model: text(column: 4, statement: statement),
                    quantity: Int(sqlite3_column_int64(statement, 5)),
                    colorCount: Int(sqlite3_column_int64(statement, 6))
                )
            )
        }
        return result
    }

    func saveBill(date: Date, rows: [EntryRow]) throws -> Bill {
        guard let db else { throw DatabaseError.openFailed("数据库未打开") }
        let billDate = DateKey.string(from: date)
        let normalizedRows = rows.normalizedForSubmission()
        guard !normalizedRows.isEmpty else { throw DatabaseError.stepFailed("账单没有有效明细") }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let lookup = try prepare("SELECT id FROM bills WHERE bill_date = ?;")
            var existingID: Int64?
            try bindText(billDate, at: 1, in: lookup)
            if sqlite3_step(lookup) == SQLITE_ROW {
                existingID = sqlite3_column_int64(lookup, 0)
            }
            sqlite3_finalize(lookup)

            let submittedAt = Date().timeIntervalSince1970
            let billID: Int64
            if let existingID {
                billID = existingID
                let update = try prepare("UPDATE bills SET submitted_at = ? WHERE id = ?;")
                defer { sqlite3_finalize(update) }
                sqlite3_bind_double(update, 1, submittedAt)
                sqlite3_bind_int64(update, 2, billID)
                try stepDone(update)

                let deleteItems = try prepare("DELETE FROM bill_items WHERE bill_id = ?;")
                defer { sqlite3_finalize(deleteItems) }
                sqlite3_bind_int64(deleteItems, 1, billID)
                try stepDone(deleteItems)
            } else {
                let insertBill = try prepare("INSERT INTO bills(bill_date, submitted_at) VALUES (?, ?);")
                defer { sqlite3_finalize(insertBill) }
                try bindText(billDate, at: 1, in: insertBill)
                sqlite3_bind_double(insertBill, 2, submittedAt)
                try stepDone(insertBill)
                billID = lastInsertID
            }

            let insertItem = try prepare("""
                INSERT INTO bill_items(bill_id, customer, employee, model, quantity, color_count)
                VALUES (?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(insertItem) }
            for row in normalizedRows {
                sqlite3_reset(insertItem)
                sqlite3_clear_bindings(insertItem)
                sqlite3_bind_int64(insertItem, 1, billID)
                try bindText(row.customer, at: 2, in: insertItem)
                try bindText(row.employee, at: 3, in: insertItem)
                try bindText(row.model, at: 4, in: insertItem)
                sqlite3_bind_int64(insertItem, 5, Int64(row.quantityValue ?? 0))
                sqlite3_bind_int64(insertItem, 6, Int64(row.colorCount))
                try stepDone(insertItem)
            }

            let deleteDraft = try prepare("DELETE FROM drafts WHERE bill_date = ?;")
            defer { sqlite3_finalize(deleteDraft) }
            try bindText(billDate, at: 1, in: deleteDraft)
            try stepDone(deleteDraft)

            try execute("COMMIT;")
            return Bill(
                id: billID,
                date: DateKey.startOfDay(date),
                submittedAt: Date(timeIntervalSince1970: submittedAt),
                items: try loadBillItems(billID: billID)
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Cloud merge

    func mergeRemoteWorkshop(_ data: RemoteWorkshopData) throws -> Int {
        guard let db else { throw DatabaseError.openFailed("数据库未打开") }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let now = Date().timeIntervalSince1970
            for entry in data.customers {
                let statement = try prepare("""
                    INSERT INTO customers(name, created_at, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at;
                    """)
                defer { sqlite3_finalize(statement) }
                let createdAt = entry.createdAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? now
                let updatedAt = entry.updatedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? createdAt
                try bindText(entry.name, at: 1, in: statement)
                sqlite3_bind_double(statement, 2, createdAt)
                sqlite3_bind_double(statement, 3, updatedAt)
                try stepDone(statement)
            }

            for entry in data.employees {
                let statement = try prepare("""
                    INSERT INTO employees(name, created_at, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at;
                    """)
                defer { sqlite3_finalize(statement) }
                let createdAt = entry.createdAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? now
                let updatedAt = entry.updatedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? createdAt
                try bindText(entry.name, at: 1, in: statement)
                sqlite3_bind_double(statement, 2, createdAt)
                sqlite3_bind_double(statement, 3, updatedAt)
                try stepDone(statement)
            }

            for remoteBill in data.bills {
                guard let date = DateKey.date(from: remoteBill.date) else {
                    throw DatabaseError.stepFailed("云端账单日期格式不正确：\(remoteBill.date)")
                }
                guard !remoteBill.items.isEmpty else {
                    throw DatabaseError.stepFailed("云端账单没有计件明细：\(remoteBill.date)")
                }
                let submittedAt = CloudDate.parse(remoteBill.submittedAt)?.timeIntervalSince1970 ?? now
                let upsert = try prepare("""
                    INSERT INTO bills(bill_date, submitted_at) VALUES (?, ?)
                    ON CONFLICT(bill_date) DO UPDATE SET submitted_at = excluded.submitted_at;
                    """)
                try bindText(remoteBill.date, at: 1, in: upsert)
                sqlite3_bind_double(upsert, 2, submittedAt)
                try stepDone(upsert)
                sqlite3_finalize(upsert)

                let lookup = try prepare("SELECT id FROM bills WHERE bill_date = ?;")
                try bindText(remoteBill.date, at: 1, in: lookup)
                guard sqlite3_step(lookup) == SQLITE_ROW else {
                    sqlite3_finalize(lookup)
                    throw DatabaseError.stepFailed("云端账单写入后无法读取：\(remoteBill.date)")
                }
                let billID = sqlite3_column_int64(lookup, 0)
                sqlite3_finalize(lookup)

                let deleteItems = try prepare("DELETE FROM bill_items WHERE bill_id = ?;")
                sqlite3_bind_int64(deleteItems, 1, billID)
                try stepDone(deleteItems)
                sqlite3_finalize(deleteItems)

                let insertItem = try prepare("""
                    INSERT INTO bill_items(bill_id, customer, employee, model, quantity, color_count)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """)
                defer { sqlite3_finalize(insertItem) }
                for item in remoteBill.items {
                    guard item.quantity > 0, (1...5).contains(item.colorCount) else {
                        throw DatabaseError.stepFailed("云端账单存在无效数量或色数：\(remoteBill.date)")
                    }
                    sqlite3_reset(insertItem)
                    sqlite3_clear_bindings(insertItem)
                    sqlite3_bind_int64(insertItem, 1, billID)
                    try bindText(item.customer, at: 2, in: insertItem)
                    try bindText(item.employee, at: 3, in: insertItem)
                    try bindText(item.model, at: 4, in: insertItem)
                    sqlite3_bind_int64(insertItem, 5, Int64(item.quantity))
                    sqlite3_bind_int64(insertItem, 6, Int64(item.colorCount))
                    try stepDone(insertItem)
                }
            }

            try execute("COMMIT;")
            return data.bills.count
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Drafts

    func saveDraft(date: Date, rows: [EntryRow]) throws {
        let billDate = DateKey.string(from: date)
        let filteredRows = rows.filter { !$0.isCompletelyEmpty }
        if filteredRows.isEmpty {
            try deleteDraft(date: date)
            return
        }
        let payload = DraftPayload(rows: filteredRows)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            throw DatabaseError.encodingFailed
        }
        let statement = try prepare("""
            INSERT INTO drafts(bill_date, payload, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(bill_date) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at;
            """)
        defer { sqlite3_finalize(statement) }
        try bindText(billDate, at: 1, in: statement)
        try bindText(json, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    func loadDraft(date: Date) throws -> [EntryRow]? {
        let statement = try prepare("SELECT payload FROM drafts WHERE bill_date = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(DateKey.string(from: date), at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let json = text(column: 0, statement: statement)
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(DraftPayload.self, from: data) else {
            return nil
        }
        return payload.rows
    }

    func deleteDraft(date: Date) throws {
        let statement = try prepare("DELETE FROM drafts WHERE bill_date = ?;")
        defer { sqlite3_finalize(statement) }
        try bindText(DateKey.string(from: date), at: 1, in: statement)
        try stepDone(statement)
    }

    func loadDraftSummaries() throws -> [DraftSummary] {
        let statement = try prepare("SELECT bill_date, updated_at FROM drafts ORDER BY bill_date DESC;")
        defer { sqlite3_finalize(statement) }
        var result: [DraftSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let dateString = text(column: 0, statement: statement)
            guard let date = DateKey.date(from: dateString) else { continue }
            let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
            result.append(DraftSummary(date: date, updatedAt: updatedAt))
        }
        return result
    }

    // MARK: - Backup

    func createBackupCopy() throws -> URL {
        guard let db else { throw DatabaseError.openFailed("数据库未打开") }
        let filename = "workshop-ledger-backup-\(DateKey.filenameTimestamp()).sqlite3"
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destinationURL)

        var destination: OpaquePointer?
        let openResult = sqlite3_open(destinationURL.path, &destination)
        guard openResult == SQLITE_OK else {
            let message = destination.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "无法创建备份文件"
            if let destination { sqlite3_close(destination) }
            throw DatabaseError.openFailed(message)
        }
        guard let destinationDatabase = destination else {
            throw DatabaseError.openFailed("无法创建备份文件")
        }
        defer { sqlite3_close(destinationDatabase) }

        guard let backup = sqlite3_backup_init(destinationDatabase, "main", db, "main") else {
            throw DatabaseError.statementFailed("无法初始化 SQLite 备份")
        }
        let result = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE else {
            throw DatabaseError.statementFailed("SQLite 备份未完成")
        }
        return destinationURL
    }
}