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

    init(accountId: String? = nil) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkshopLedger", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let databaseURL: URL
        if let accountId {
            let accountsRoot = support.appendingPathComponent("accounts", isDirectory: true)
            let accountRoot = accountsRoot.appendingPathComponent(Self.safeAccountDirectoryName(accountId), isDirectory: true)
            try FileManager.default.createDirectory(at: accountRoot, withIntermediateDirectories: true)
            databaseURL = accountRoot.appendingPathComponent("workshop-ledger.sqlite3")
            try Self.importLegacyDatabaseIfNeeded(
                accountId: accountId,
                supportRoot: support,
                destinationURL: databaseURL
            )
        } else {
            databaseURL = support.appendingPathComponent("workshop-ledger.sqlite3")
        }
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

    private static func safeAccountDirectoryName(_ accountId: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !accountId.isEmpty,
              accountId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "invalid-account"
        }
        return accountId
    }

    private static func importLegacyDatabaseIfNeeded(
        accountId: String,
        supportRoot: URL,
        destinationURL: URL
    ) throws {
        let fileManager = FileManager.default
        let legacyURL = supportRoot.appendingPathComponent("workshop-ledger.sqlite3")
        let accountsRoot = supportRoot.appendingPathComponent("accounts", isDirectory: true)
        let markerURL = accountsRoot.appendingPathComponent(".legacy-imported-account")
        guard !fileManager.fileExists(atPath: destinationURL.path),
              fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: markerURL.path) else {
            return
        }

        var source: OpaquePointer?
        var destination: OpaquePointer?
        defer {
            if let destination { sqlite3_close(destination) }
            if let source { sqlite3_close(source) }
        }
        do {
            guard sqlite3_open_v2(
                legacyURL.path,
                &source,
                SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
                nil
            ) == SQLITE_OK else {
                throw DatabaseError.openFailed("旧版本机数据库无法打开")
            }
            guard sqlite3_open(destinationURL.path, &destination) == SQLITE_OK else {
                throw DatabaseError.openFailed("新版本机数据库无法创建")
            }
            guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
                throw DatabaseError.statementFailed("无法迁移旧版本机数据库")
            }
            let result = sqlite3_backup_step(backup, -1)
            let finishResult = sqlite3_backup_finish(backup)
            guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
                throw DatabaseError.statementFailed("旧版本机数据库迁移未完成")
            }
            try Data(accountId.utf8).write(to: markerURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    static func deleteAccountDatabase(accountId: String) throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WorkshopLedger", isDirectory: true)
        let accountRoot = support
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(safeAccountDirectoryName(accountId), isDirectory: true)
        guard FileManager.default.fileExists(atPath: accountRoot.path) else { return }
        try FileManager.default.removeItem(at: accountRoot)
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

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement = try prepare(sql)
        do {
            let result = try body(statement)
            sqlite3_finalize(statement)
            return result
        } catch {
            sqlite3_finalize(statement)
            throw error
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

    private func optionalInt64(column: Int32, statement: OpaquePointer) -> Int64? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    private var lastInsertID: Int64 {
        guard let db else { return 0 }
        return sqlite3_last_insert_rowid(db)
    }

    private func bindOptionalInt64(_ value: Int64?, at index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    // MARK: - Directory

    func loadCustomers() throws -> [Customer] {
        let statement = try prepare("SELECT id, name, unit_price_cents, created_at, updated_at FROM customers ORDER BY name COLLATE NOCASE;")
        defer { sqlite3_finalize(statement) }
        var result: [Customer] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                Customer(
                    id: sqlite3_column_int64(statement, 0),
                    name: text(column: 1, statement: statement),
                    unitPriceCents: optionalInt64(column: 2, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                )
            )
        }
        return result
    }

    func addCustomer(name: String, unitPriceCents: Int64? = nil) throws -> Customer {
        let statement = try prepare("INSERT INTO customers(name, unit_price_cents, created_at, updated_at) VALUES (?, ?, ?, ?);")
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        try bindText(name, at: 1, in: statement)
        bindOptionalInt64(unitPriceCents, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        try stepDone(statement)
        return Customer(
            id: lastInsertID,
            name: name,
            unitPriceCents: unitPriceCents,
            createdAt: Date(timeIntervalSince1970: now),
            updatedAt: Date(timeIntervalSince1970: now)
        )
    }

    func updateCustomer(
        id: Int64,
        name: String,
        unitPriceCents: Int64?,
        backfillHistoricalPrices: Bool
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var previousName = name
            try withStatement("SELECT name FROM customers WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
                if sqlite3_step(statement) == SQLITE_ROW {
                    previousName = text(column: 0, statement: statement)
                } else {
                    throw DatabaseError.stepFailed("客户档案不存在")
                }
            }
            let now = Date().timeIntervalSince1970
            try withStatement("""
                UPDATE customers
                SET name = ?, unit_price_cents = ?, updated_at = ?
                WHERE id = ?;
                """) { statement in
                try bindText(name, at: 1, in: statement)
                bindOptionalInt64(unitPriceCents, at: 2, in: statement)
                sqlite3_bind_double(statement, 3, now)
                sqlite3_bind_int64(statement, 4, id)
                try stepDone(statement)
            }
            if backfillHistoricalPrices, let unitPriceCents {
                try withStatement("""
                    UPDATE bill_items
                    SET unit_price_cents = ?
                    WHERE (customer = ? OR customer = ?)
                      AND unit_price_cents IS NULL;
                    """) { statement in
                    sqlite3_bind_int64(statement, 1, unitPriceCents)
                    try bindText(previousName, at: 2, in: statement)
                    try bindText(name, at: 3, in: statement)
                    try stepDone(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
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
            SELECT id, bill_id, customer, employee, model, quantity, color_count,
                   unit_price_cents, settlement_batch_id
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
                    colorCount: Int(sqlite3_column_int64(statement, 6)),
                    unitPriceCents: optionalInt64(column: 7, statement: statement),
                    settlementBatchID: optionalInt64(column: 8, statement: statement)
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
            var existingBillID: Int64?
            try withStatement("SELECT id FROM bills WHERE bill_date = ?;") { statement in
                try bindText(billDate, at: 1, in: statement)
                if sqlite3_step(statement) == SQLITE_ROW {
                    existingBillID = sqlite3_column_int64(statement, 0)
                }
            }

            let submittedAt = Date().timeIntervalSince1970
            let billID: Int64
            if let existingBillID {
                billID = existingBillID
                try withStatement("UPDATE bills SET submitted_at = ? WHERE id = ?;") { statement in
                    sqlite3_bind_double(statement, 1, submittedAt)
                    sqlite3_bind_int64(statement, 2, billID)
                    try stepDone(statement)
                }
            } else {
                try withStatement("INSERT INTO bills(bill_date, submitted_at) VALUES (?, ?);") { statement in
                    try bindText(billDate, at: 1, in: statement)
                    sqlite3_bind_double(statement, 2, submittedAt)
                    try stepDone(statement)
                }
                billID = lastInsertID
            }

            let existingItems = try loadBillItems(billID: billID)
            let existingByID = Dictionary(uniqueKeysWithValues: existingItems.map { ($0.id, $0) })
            let incomingExistingIDs = Set(normalizedRows.compactMap(\.existingItemID))
            if existingItems.contains(where: { $0.settlementBatchID != nil && !incomingExistingIDs.contains($0.id) }) {
                throw DatabaseError.stepFailed("已结清流水已锁定，不能删除。请先撤销对应结清批次。")
            }

            var prices: [String: Int64] = [:]
            try withStatement("SELECT name, unit_price_cents FROM customers WHERE unit_price_cents IS NOT NULL;") { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    prices[text(column: 0, statement: statement).lowercased()] = sqlite3_column_int64(statement, 1)
                }
            }

            let updateItem = try prepare("""
                UPDATE bill_items
                SET customer = ?, employee = ?, model = ?, quantity = ?, color_count = ?, unit_price_cents = ?
                WHERE id = ? AND bill_id = ? AND settlement_batch_id IS NULL;
                """)
            defer { sqlite3_finalize(updateItem) }
            let insertItem = try prepare("""
                INSERT INTO bill_items(bill_id, customer, employee, model, quantity, color_count, unit_price_cents)
                VALUES (?, ?, ?, ?, ?, ?, ?);
                """)
            defer { sqlite3_finalize(insertItem) }

            for row in normalizedRows {
                let existing = row.existingItemID.flatMap { existingByID[$0] }
                if let existing, existing.settlementBatchID != nil {
                    let unchanged = existing.customer == row.customer
                        && existing.employee == row.employee
                        && existing.model == row.model
                        && existing.quantity == (row.quantityValue ?? 0)
                        && existing.colorCount == row.colorCount
                    guard unchanged else {
                        throw DatabaseError.stepFailed("已结清流水已锁定，不能修改。请先撤销对应结清批次。")
                    }
                    continue
                }

                let unitPrice: Int64
                if let existing,
                   existing.customer == row.customer,
                   let historicalPrice = existing.unitPriceCents {
                    unitPrice = historicalPrice
                } else if let currentPrice = prices[row.customer.lowercased()] {
                    unitPrice = currentPrice
                } else {
                    throw DatabaseError.stepFailed("客户“\(row.customer)”尚未设置加工单价，请先到客户管理页设置。")
                }

                if let existing {
                    sqlite3_reset(updateItem)
                    sqlite3_clear_bindings(updateItem)
                    try bindText(row.customer, at: 1, in: updateItem)
                    try bindText(row.employee, at: 2, in: updateItem)
                    try bindText(row.model, at: 3, in: updateItem)
                    sqlite3_bind_int64(updateItem, 4, Int64(row.quantityValue ?? 0))
                    sqlite3_bind_int64(updateItem, 5, Int64(row.colorCount))
                    sqlite3_bind_int64(updateItem, 6, unitPrice)
                    sqlite3_bind_int64(updateItem, 7, existing.id)
                    sqlite3_bind_int64(updateItem, 8, billID)
                    try stepDone(updateItem)
                } else {
                    sqlite3_reset(insertItem)
                    sqlite3_clear_bindings(insertItem)
                    sqlite3_bind_int64(insertItem, 1, billID)
                    try bindText(row.customer, at: 2, in: insertItem)
                    try bindText(row.employee, at: 3, in: insertItem)
                    try bindText(row.model, at: 4, in: insertItem)
                    sqlite3_bind_int64(insertItem, 5, Int64(row.quantityValue ?? 0))
                    sqlite3_bind_int64(insertItem, 6, Int64(row.colorCount))
                    sqlite3_bind_int64(insertItem, 7, unitPrice)
                    try stepDone(insertItem)
                }
            }

            for item in existingItems where item.settlementBatchID == nil && !incomingExistingIDs.contains(item.id) {
                try withStatement("DELETE FROM bill_items WHERE id = ?;") { statement in
                    sqlite3_bind_int64(statement, 1, item.id)
                    try stepDone(statement)
                }
            }

            try withStatement("DELETE FROM drafts WHERE bill_date = ?;") { statement in
                try bindText(billDate, at: 1, in: statement)
                try stepDone(statement)
            }

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

    // MARK: - Settlement

    func createSettlementBatch(
        itemIDs: [Int64],
        settlementDate: Date,
        actualAmountCents: Int64,
        note: String
    ) throws -> SettlementBatch {
        guard let db else { throw DatabaseError.openFailed("数据库未打开") }
        let uniqueIDs = Array(Set(itemIDs)).sorted()
        guard !uniqueIDs.isEmpty else { throw DatabaseError.stepFailed("请选择要结清的流水。") }
        guard actualAmountCents >= 0 else { throw DatabaseError.stepFailed("实际结款金额不能为负数。") }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
            var selected: [(id: Int64, customer: String, price: Int64, quantity: Int64, color: Int64, batch: Int64?)] = []
            try withStatement("""
                SELECT id, customer, unit_price_cents, quantity, color_count, settlement_batch_id
                FROM bill_items WHERE id IN (\(placeholders)) ORDER BY id;
                """) { statement in
                for (offset, id) in uniqueIDs.enumerated() {
                    sqlite3_bind_int64(statement, Int32(offset + 1), id)
                }
                while sqlite3_step(statement) == SQLITE_ROW {
                    selected.append((
                        sqlite3_column_int64(statement, 0),
                        text(column: 1, statement: statement),
                        optionalInt64(column: 2, statement: statement) ?? 0,
                        sqlite3_column_int64(statement, 3),
                        sqlite3_column_int64(statement, 4),
                        optionalInt64(column: 5, statement: statement)
                    ))
                }
            }
            guard selected.count == uniqueIDs.count else {
                throw DatabaseError.stepFailed("部分流水已不存在，请刷新后重试。")
            }
            guard !selected.contains(where: { $0.batch != nil }) else {
                throw DatabaseError.stepFailed("所选流水中含有已结清记录，请刷新后重试。")
            }
            guard let customer = selected.first?.customer,
                  selected.allSatisfy({ $0.customer == customer }) else {
                throw DatabaseError.stepFailed("同一结清批次只能选择同一客户的流水。")
            }
            guard !selected.contains(where: { $0.price <= 0 }) else {
                throw DatabaseError.stepFailed("部分流水尚未设置加工单价，不能结清。")
            }

            let receivable = selected.reduce(Int64(0)) { $0 + $1.price * $1.quantity * $1.color }
            let day = DateKey.string(from: settlementDate)
            let prefix = "QZ-\(day.replacingOccurrences(of: "-", with: ""))-"
            var sequence = 1
            try withStatement("SELECT COUNT(*) FROM settlement_batches WHERE batch_no LIKE ?;") { statement in
                try bindText(prefix + "%", at: 1, in: statement)
                if sqlite3_step(statement) == SQLITE_ROW {
                    sequence = Int(sqlite3_column_int64(statement, 0)) + 1
                }
            }
            var batchNo = "\(prefix)\(String(format: "%03d", sequence))"
            while try settlementBatchExists(batchNo) {
                sequence += 1
                batchNo = "\(prefix)\(String(format: "%03d", sequence))"
            }

            let createdAt = Date().timeIntervalSince1970
            try withStatement("""
                INSERT INTO settlement_batches(
                    batch_no, customer, settlement_date, receivable_cents,
                    actual_amount_cents, note, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                try bindText(batchNo, at: 1, in: statement)
                try bindText(customer, at: 2, in: statement)
                try bindText(day, at: 3, in: statement)
                sqlite3_bind_int64(statement, 4, receivable)
                sqlite3_bind_int64(statement, 5, actualAmountCents)
                try bindText(String(note.prefix(200)), at: 6, in: statement)
                sqlite3_bind_double(statement, 7, createdAt)
                try stepDone(statement)
            }
            let batchID = lastInsertID
            try withStatement("""
                UPDATE bill_items SET settlement_batch_id = ?
                WHERE id IN (\(placeholders)) AND settlement_batch_id IS NULL;
                """) { statement in
                sqlite3_bind_int64(statement, 1, batchID)
                for (offset, id) in uniqueIDs.enumerated() {
                    sqlite3_bind_int64(statement, Int32(offset + 2), id)
                }
                try stepDone(statement)
            }
            guard sqlite3_changes(db) == Int32(uniqueIDs.count) else {
                throw DatabaseError.stepFailed("结清状态更新失败，请刷新后重试。")
            }

            try execute("COMMIT;")
            return SettlementBatch(
                id: batchID,
                batchNo: batchNo,
                customer: customer,
                settlementDate: settlementDate,
                receivableCents: receivable,
                actualAmountCents: actualAmountCents,
                note: String(note.prefix(200)),
                createdAt: Date(timeIntervalSince1970: createdAt),
                revokedAt: nil
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func settlementBatchExists(_ batchNo: String) throws -> Bool {
        try withStatement("SELECT 1 FROM settlement_batches WHERE batch_no = ? LIMIT 1;") { statement in
            try bindText(batchNo, at: 1, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func revokeSettlementBatch(id: Int64) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var exists = false
            try withStatement("SELECT revoked_at FROM settlement_batches WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
                if sqlite3_step(statement) == SQLITE_ROW {
                    exists = sqlite3_column_type(statement, 0) == SQLITE_NULL
                }
            }
            guard exists else { throw DatabaseError.stepFailed("该结清批次不存在或已撤销。") }
            try withStatement("UPDATE bill_items SET settlement_batch_id = NULL WHERE settlement_batch_id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
                try stepDone(statement)
            }
            try withStatement("UPDATE settlement_batches SET revoked_at = ? WHERE id = ?;") { statement in
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                sqlite3_bind_int64(statement, 2, id)
                try stepDone(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func loadSettlementBatches(includeRevoked: Bool = false) throws -> [SettlementBatch] {
        let filter = includeRevoked ? "" : "WHERE revoked_at IS NULL"
        let statement = try prepare("""
            SELECT id, batch_no, customer, settlement_date, receivable_cents,
                   actual_amount_cents, note, created_at, revoked_at
            FROM settlement_batches
            \(filter)
            ORDER BY settlement_date DESC, id DESC;
            """)
        defer { sqlite3_finalize(statement) }
        var result: [SettlementBatch] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let day = text(column: 3, statement: statement)
            guard let settlementDate = DateKey.date(from: day) else { continue }
            let revokedAt = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            result.append(
                SettlementBatch(
                    id: sqlite3_column_int64(statement, 0),
                    batchNo: text(column: 1, statement: statement),
                    customer: text(column: 2, statement: statement),
                    settlementDate: settlementDate,
                    receivableCents: sqlite3_column_int64(statement, 4),
                    actualAmountCents: sqlite3_column_int64(statement, 5),
                    note: text(column: 6, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    revokedAt: revokedAt
                )
            )
        }
        return result
    }

    // MARK: - Cloud merge

    func mergeRemoteWorkshop(_ data: RemoteWorkshopData) throws -> Int {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let now = Date().timeIntervalSince1970

            for entry in data.customers {
                try withStatement("""
                    INSERT INTO customers(name, unit_price_cents, created_at, updated_at) VALUES (?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        unit_price_cents = COALESCE(excluded.unit_price_cents, customers.unit_price_cents),
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at;
                    """) { statement in
                    let createdAt = entry.createdAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? now
                    let updatedAt = entry.updatedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? createdAt
                    try bindText(entry.name, at: 1, in: statement)
                    bindOptionalInt64(entry.unitPriceCents, at: 2, in: statement)
                    sqlite3_bind_double(statement, 3, createdAt)
                    sqlite3_bind_double(statement, 4, updatedAt)
                    try stepDone(statement)
                }
            }

            for entry in data.employees {
                try withStatement("""
                    INSERT INTO employees(name, created_at, updated_at) VALUES (?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at;
                    """) { statement in
                    let createdAt = entry.createdAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? now
                    let updatedAt = entry.updatedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? createdAt
                    try bindText(entry.name, at: 1, in: statement)
                    sqlite3_bind_double(statement, 2, createdAt)
                    sqlite3_bind_double(statement, 3, updatedAt)
                    try stepDone(statement)
                }
            }

            var batchIDsByNumber: [String: Int64] = [:]
            var activeBatchNumbers: Set<String> = []
            for batch in data.settlementBatches ?? [] {
                try withStatement("""
                    INSERT INTO settlement_batches(
                        batch_no, customer, settlement_date, receivable_cents,
                        actual_amount_cents, note, created_at, revoked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(batch_no) DO UPDATE SET
                        customer = excluded.customer,
                        settlement_date = excluded.settlement_date,
                        receivable_cents = excluded.receivable_cents,
                        actual_amount_cents = excluded.actual_amount_cents,
                        note = excluded.note,
                        created_at = excluded.created_at,
                        revoked_at = excluded.revoked_at;
                    """) { statement in
                    let createdAt = CloudDate.parse(batch.createdAt)?.timeIntervalSince1970 ?? now
                    let revokedAt = batch.revokedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970
                    try bindText(batch.batchNo, at: 1, in: statement)
                    try bindText(batch.customer, at: 2, in: statement)
                    try bindText(batch.settlementDate, at: 3, in: statement)
                    sqlite3_bind_int64(statement, 4, batch.receivableCents)
                    sqlite3_bind_int64(statement, 5, batch.actualAmountCents)
                    try bindText(batch.note, at: 6, in: statement)
                    sqlite3_bind_double(statement, 7, createdAt)
                    if let revokedAt {
                        sqlite3_bind_double(statement, 8, revokedAt)
                    } else {
                        sqlite3_bind_null(statement, 8)
                        activeBatchNumbers.insert(batch.batchNo)
                    }
                    try stepDone(statement)
                }
                let batchID: Int64 = try withStatement("SELECT id FROM settlement_batches WHERE batch_no = ?;") { statement in
                    try bindText(batch.batchNo, at: 1, in: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        throw DatabaseError.stepFailed("云端结清批次写入后无法读取：\(batch.batchNo)")
                    }
                    return sqlite3_column_int64(statement, 0)
                }
                batchIDsByNumber[batch.batchNo] = batchID
            }

            for remoteBill in data.bills {
                guard let date = DateKey.date(from: remoteBill.date) else {
                    throw DatabaseError.stepFailed("云端账单日期格式不正确：\(remoteBill.date)")
                }
                guard !remoteBill.items.isEmpty else {
                    throw DatabaseError.stepFailed("云端账单没有计件明细：\(remoteBill.date)")
                }
                let submittedAt = CloudDate.parse(remoteBill.submittedAt)?.timeIntervalSince1970 ?? now
                try withStatement("""
                    INSERT INTO bills(bill_date, submitted_at) VALUES (?, ?)
                    ON CONFLICT(bill_date) DO UPDATE SET submitted_at = excluded.submitted_at;
                    """) { statement in
                    try bindText(remoteBill.date, at: 1, in: statement)
                    sqlite3_bind_double(statement, 2, submittedAt)
                    try stepDone(statement)
                }

                let billID: Int64 = try withStatement("SELECT id FROM bills WHERE bill_date = ?;") { statement in
                    try bindText(remoteBill.date, at: 1, in: statement)
                    guard sqlite3_step(statement) == SQLITE_ROW else {
                        throw DatabaseError.stepFailed("云端账单写入后无法读取：\(remoteBill.date)")
                    }
                    return sqlite3_column_int64(statement, 0)
                }

                let localItemsBeforeMerge = try loadBillItems(billID: billID)
                try withStatement("DELETE FROM bill_items WHERE bill_id = ?;") { statement in
                    sqlite3_bind_int64(statement, 1, billID)
                    try stepDone(statement)
                }

                try withStatement("""
                    INSERT INTO bill_items(
                        bill_id, customer, employee, model, quantity, color_count,
                        unit_price_cents, settlement_batch_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                    """) { insertItem in
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
                        let preservedPrice = item.unitPriceCents ?? localItemsBeforeMerge.first(where: {
                            $0.customer == item.customer
                                && $0.employee == item.employee
                                && $0.model == item.model
                                && $0.quantity == item.quantity
                                && $0.colorCount == item.colorCount
                        })?.unitPriceCents
                        bindOptionalInt64(preservedPrice, at: 7, in: insertItem)
                        if let batchNo = item.settlementBatchNo,
                           activeBatchNumbers.contains(batchNo),
                           let batchID = batchIDsByNumber[batchNo] {
                            sqlite3_bind_int64(insertItem, 8, batchID)
                        } else {
                            sqlite3_bind_null(insertItem, 8)
                        }
                        try stepDone(insertItem)
                    }
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