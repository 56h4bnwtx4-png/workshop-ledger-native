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
        try backupBeforeV15MigrationIfNeeded()
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

    private func backupBeforeV15MigrationIfNeeded() throws {
        let version = try currentSchemaVersion()
        guard version < 3 else { return }
        let hasExistingTables = try withStatement("""
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name IN ('customers', 'employees', 'bills', 'bill_items');
            """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return sqlite3_column_int64(statement, 0) > 0
        }
        guard hasExistingTables else { return }

        let folder = databaseURL.deletingLastPathComponent()
        let filename = "workshop-ledger-pre-v1.5.0-\(DateKey.filenameTimestamp()).sqlite3"
        let destinationURL = folder.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destinationURL)

        guard let source = db else { throw DatabaseError.openFailed("数据库未打开") }
        var destination: OpaquePointer?
        guard sqlite3_open(destinationURL.path, &destination) == SQLITE_OK else {
            let message = destination.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "无法创建升级前备份"
            if let destination { sqlite3_close(destination) }
            throw DatabaseError.openFailed(message)
        }
        defer { if let destination { sqlite3_close(destination) } }
        guard let destination, let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DatabaseError.statementFailed("无法开始备份 v1.4 数据库")
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw DatabaseError.statementFailed("v1.4 数据库升级前备份失败")
        }
    }

    private func currentSchemaVersion() throws -> Int {
        try withStatement("PRAGMA user_version;") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func migrate() throws {
        try execute("PRAGMA foreign_keys = ON;")
        let previousVersion = try currentSchemaVersion()
        let hadExistingSchema = try withStatement("""
            SELECT COUNT(*) FROM sqlite_master
            WHERE type = 'table' AND name IN ('customers', 'employees', 'bills', 'bill_items');
            """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            return sqlite3_column_int64(statement, 0) > 0
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS customers (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                unit_price_milli_yuan INTEGER,
                settlement_mode TEXT NOT NULL DEFAULT 'batch',
                created_at REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS employees (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE COLLATE NOCASE,
                wage_milli_yuan INTEGER,
                created_at REAL NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS bills (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bill_date TEXT NOT NULL UNIQUE,
                submitted_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS settlement_batches (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                batch_no TEXT NOT NULL UNIQUE,
                customer TEXT NOT NULL,
                settlement_date TEXT NOT NULL,
                receivable_milli_yuan INTEGER NOT NULL DEFAULT 0,
                actual_amount_milli_yuan INTEGER NOT NULL DEFAULT 0,
                note TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                revoked_at REAL
            );
            CREATE TABLE IF NOT EXISTS customer_receipts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                receipt_no TEXT NOT NULL UNIQUE,
                customer TEXT NOT NULL,
                amount_milli_yuan INTEGER NOT NULL,
                receipt_date TEXT NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                revoked_at REAL
            );
            CREATE TABLE IF NOT EXISTS employee_payments (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                payment_no TEXT NOT NULL UNIQUE,
                employee TEXT NOT NULL,
                amount_milli_yuan INTEGER NOT NULL,
                payment_date TEXT NOT NULL,
                note TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL,
                revoked_at REAL
            );
            CREATE TABLE IF NOT EXISTS bill_items (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                bill_id INTEGER NOT NULL,
                customer TEXT NOT NULL,
                employee TEXT NOT NULL,
                model TEXT NOT NULL,
                quantity INTEGER NOT NULL,
                color_count INTEGER NOT NULL,
                unit_price_milli_yuan INTEGER,
                employee_wage_milli_yuan INTEGER,
                settlement_batch_id INTEGER,
                FOREIGN KEY (bill_id) REFERENCES bills(id) ON DELETE CASCADE,
                FOREIGN KEY (settlement_batch_id) REFERENCES settlement_batches(id) ON DELETE SET NULL
            );
            CREATE INDEX IF NOT EXISTS idx_bill_items_bill_id ON bill_items(bill_id);
            CREATE INDEX IF NOT EXISTS idx_bills_date ON bills(bill_date DESC);
            CREATE INDEX IF NOT EXISTS idx_settlement_batches_customer ON settlement_batches(customer, settlement_date DESC);
            CREATE INDEX IF NOT EXISTS idx_customer_receipts_customer ON customer_receipts(customer, receipt_date DESC);
            CREATE INDEX IF NOT EXISTS idx_employee_payments_employee ON employee_payments(employee, payment_date DESC);
            CREATE TABLE IF NOT EXISTS drafts (
                bill_date TEXT PRIMARY KEY,
                payload TEXT NOT NULL,
                updated_at REAL NOT NULL
            );
            """)

        // Bring v1.4 databases forward without deleting bills or directory records.
        try? execute("ALTER TABLE customers ADD COLUMN created_at REAL NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE customers ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE customers ADD COLUMN unit_price_milli_yuan INTEGER;")
        try? execute("ALTER TABLE customers ADD COLUMN settlement_mode TEXT NOT NULL DEFAULT 'batch';")
        try? execute("ALTER TABLE employees ADD COLUMN created_at REAL NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE employees ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE employees ADD COLUMN wage_milli_yuan INTEGER;")
        try? execute("ALTER TABLE bill_items ADD COLUMN unit_price_milli_yuan INTEGER;")
        try? execute("ALTER TABLE bill_items ADD COLUMN employee_wage_milli_yuan INTEGER;")
        try? execute("ALTER TABLE bill_items ADD COLUMN settlement_batch_id INTEGER;")
        try? execute("ALTER TABLE settlement_batches ADD COLUMN receivable_milli_yuan INTEGER NOT NULL DEFAULT 0;")
        try? execute("ALTER TABLE settlement_batches ADD COLUMN actual_amount_milli_yuan INTEGER NOT NULL DEFAULT 0;")

        if previousVersion < 3 && hadExistingSchema {
            // v1.4 stored money in cents. Preserve settlement history by converting it once.
            try? execute("""
                UPDATE settlement_batches
                SET receivable_milli_yuan = receivable_cents * 10,
                    actual_amount_milli_yuan = actual_amount_cents * 10
                WHERE receivable_milli_yuan = 0 AND actual_amount_milli_yuan = 0;
                """)
            // The user requested a clean pricing restart for v1.5. Old prices must not be reused.
            try? execute("UPDATE customers SET unit_price_milli_yuan = NULL, unit_price_cents = NULL;")
            try? execute("UPDATE bill_items SET unit_price_milli_yuan = NULL, employee_wage_milli_yuan = NULL, unit_price_cents = NULL;")
        }

        try execute("""
            UPDATE customers
            SET settlement_mode = CASE
                    WHEN settlement_mode IN ('batch', 'annual') THEN settlement_mode
                    ELSE 'batch'
                END,
                created_at = CASE WHEN created_at = 0 THEN strftime('%s','now') ELSE created_at END,
                updated_at = CASE WHEN updated_at = 0 THEN strftime('%s','now') ELSE updated_at END;
            UPDATE employees
            SET created_at = CASE WHEN created_at = 0 THEN strftime('%s','now') ELSE created_at END,
                updated_at = CASE WHEN updated_at = 0 THEN strftime('%s','now') ELSE updated_at END;
            CREATE INDEX IF NOT EXISTS idx_settlement_batches_customer ON settlement_batches(customer, settlement_date DESC);
            CREATE INDEX IF NOT EXISTS idx_customer_receipts_customer ON customer_receipts(customer, receipt_date DESC);
            CREATE INDEX IF NOT EXISTS idx_employee_payments_employee ON employee_payments(employee, payment_date DESC);
            CREATE INDEX IF NOT EXISTS idx_bill_items_settlement_batch_id ON bill_items(settlement_batch_id);
            PRAGMA user_version = 3;
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
        let statement = try prepare("""
            SELECT id, name, unit_price_milli_yuan, settlement_mode, created_at, updated_at
            FROM customers ORDER BY name COLLATE NOCASE;
            """)
        defer { sqlite3_finalize(statement) }
        var result: [Customer] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                Customer(
                    id: sqlite3_column_int64(statement, 0),
                    name: text(column: 1, statement: statement),
                    unitPriceMilliYuan: optionalInt64(column: 2, statement: statement),
                    settlementMode: CustomerSettlementMode.parse(text(column: 3, statement: statement)) ?? .batch,
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5))
                )
            )
        }
        return result
    }

    func addCustomer(
        name: String,
        unitPriceMilliYuan: Int64? = nil,
        settlementMode: CustomerSettlementMode
    ) throws -> Customer {
        let statement = try prepare("""
            INSERT INTO customers(name, unit_price_milli_yuan, settlement_mode, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        try bindText(name, at: 1, in: statement)
        bindOptionalInt64(unitPriceMilliYuan, at: 2, in: statement)
        try bindText(settlementMode.rawValue, at: 3, in: statement)
        sqlite3_bind_double(statement, 4, now)
        sqlite3_bind_double(statement, 5, now)
        try stepDone(statement)
        return Customer(
            id: lastInsertID,
            name: name,
            unitPriceMilliYuan: unitPriceMilliYuan,
            settlementMode: settlementMode,
            createdAt: Date(timeIntervalSince1970: now),
            updatedAt: Date(timeIntervalSince1970: now)
        )
    }

    func updateCustomer(
        id: Int64,
        name: String,
        unitPriceMilliYuan: Int64?,
        settlementMode: CustomerSettlementMode,
        backfillHistoricalPrices: Bool
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var previousName = name
            var previousMode = CustomerSettlementMode.batch
            try withStatement("SELECT name, settlement_mode FROM customers WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
                if sqlite3_step(statement) == SQLITE_ROW {
                    previousName = text(column: 0, statement: statement)
                    previousMode = CustomerSettlementMode.parse(text(column: 1, statement: statement)) ?? .batch
                } else {
                    throw DatabaseError.stepFailed("客户档案不存在")
                }
            }

            if previousMode != settlementMode,
               try hasActiveCustomerSettlement(previousName: previousName, currentName: name) {
                throw DatabaseError.stepFailed("该客户已有结款或回款记录，不能更换结算方式；请先撤销全部结款和回款。")
            }

            let now = Date().timeIntervalSince1970
            try withStatement("""
                UPDATE customers
                SET name = ?, unit_price_milli_yuan = ?, settlement_mode = ?, updated_at = ?
                WHERE id = ?;
                """) { statement in
                try bindText(name, at: 1, in: statement)
                bindOptionalInt64(unitPriceMilliYuan, at: 2, in: statement)
                try bindText(settlementMode.rawValue, at: 3, in: statement)
                sqlite3_bind_double(statement, 4, now)
                sqlite3_bind_int64(statement, 5, id)
                try stepDone(statement)
            }
            if backfillHistoricalPrices, let unitPriceMilliYuan {
                try withStatement("""
                    UPDATE bill_items
                    SET unit_price_milli_yuan = ?
                    WHERE (customer = ? OR customer = ?)
                      AND unit_price_milli_yuan IS NULL;
                    """) { statement in
                    sqlite3_bind_int64(statement, 1, unitPriceMilliYuan)
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

    private func hasActiveCustomerSettlement(previousName: String, currentName: String) throws -> Bool {
        try withStatement("""
            SELECT 1 FROM settlement_batches
            WHERE customer IN (?, ?) AND revoked_at IS NULL
            UNION ALL
            SELECT 1 FROM customer_receipts
            WHERE customer IN (?, ?) AND revoked_at IS NULL
            LIMIT 1;
            """) { statement in
            try bindText(previousName, at: 1, in: statement)
            try bindText(currentName, at: 2, in: statement)
            try bindText(previousName, at: 3, in: statement)
            try bindText(currentName, at: 4, in: statement)
            return sqlite3_step(statement) == SQLITE_ROW
        }
    }

    func deleteCustomer(id: Int64) throws {
        let statement = try prepare("DELETE FROM customers WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        try stepDone(statement)
    }

    func loadEmployees() throws -> [Employee] {
        let statement = try prepare("""
            SELECT id, name, wage_milli_yuan, created_at, updated_at
            FROM employees ORDER BY name COLLATE NOCASE;
            """)
        defer { sqlite3_finalize(statement) }
        var result: [Employee] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(
                Employee(
                    id: sqlite3_column_int64(statement, 0),
                    name: text(column: 1, statement: statement),
                    wageMilliYuan: optionalInt64(column: 2, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                )
            )
        }
        return result
    }

    func addEmployee(name: String, wageMilliYuan: Int64? = nil) throws -> Employee {
        let statement = try prepare("""
            INSERT INTO employees(name, wage_milli_yuan, created_at, updated_at)
            VALUES (?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        let now = Date().timeIntervalSince1970
        try bindText(name, at: 1, in: statement)
        bindOptionalInt64(wageMilliYuan, at: 2, in: statement)
        sqlite3_bind_double(statement, 3, now)
        sqlite3_bind_double(statement, 4, now)
        try stepDone(statement)
        return Employee(
            id: lastInsertID,
            name: name,
            wageMilliYuan: wageMilliYuan,
            createdAt: Date(timeIntervalSince1970: now),
            updatedAt: Date(timeIntervalSince1970: now)
        )
    }

    func updateEmployee(
        id: Int64,
        name: String,
        wageMilliYuan: Int64?,
        backfillHistoricalWages: Bool
    ) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var previousName = name
            try withStatement("SELECT name FROM employees WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, id)
                if sqlite3_step(statement) == SQLITE_ROW {
                    previousName = text(column: 0, statement: statement)
                } else {
                    throw DatabaseError.stepFailed("员工档案不存在")
                }
            }
            try withStatement("""
                UPDATE employees SET name = ?, wage_milli_yuan = ?, updated_at = ? WHERE id = ?;
                """) { statement in
                try bindText(name, at: 1, in: statement)
                bindOptionalInt64(wageMilliYuan, at: 2, in: statement)
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                sqlite3_bind_int64(statement, 4, id)
                try stepDone(statement)
            }
            if backfillHistoricalWages, let wageMilliYuan {
                try withStatement("""
                    UPDATE bill_items
                    SET employee_wage_milli_yuan = ?
                    WHERE (employee = ? OR employee = ?)
                      AND employee_wage_milli_yuan IS NULL;
                    """) { statement in
                    sqlite3_bind_int64(statement, 1, wageMilliYuan)
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
                   unit_price_milli_yuan, employee_wage_milli_yuan, settlement_batch_id
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
                    unitPriceMilliYuan: optionalInt64(column: 7, statement: statement),
                    employeeWageMilliYuan: optionalInt64(column: 8, statement: statement),
                    settlementBatchID: optionalInt64(column: 9, statement: statement)
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

            var customerPrices: [String: Int64] = [:]
            try withStatement("""
                SELECT name, unit_price_milli_yuan FROM customers
                WHERE unit_price_milli_yuan IS NOT NULL;
                """) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    customerPrices[text(column: 0, statement: statement).lowercased()] = sqlite3_column_int64(statement, 1)
                }
            }
            var employeeWages: [String: Int64] = [:]
            try withStatement("""
                SELECT name, wage_milli_yuan FROM employees
                WHERE wage_milli_yuan IS NOT NULL;
                """) { statement in
                while sqlite3_step(statement) == SQLITE_ROW {
                    employeeWages[text(column: 0, statement: statement).lowercased()] = sqlite3_column_int64(statement, 1)
                }
            }

            let updateItem = try prepare("""
                UPDATE bill_items
                SET customer = ?, employee = ?, model = ?, quantity = ?, color_count = ?,
                    unit_price_milli_yuan = ?, employee_wage_milli_yuan = ?
                WHERE id = ? AND bill_id = ? AND settlement_batch_id IS NULL;
                """)
            defer { sqlite3_finalize(updateItem) }
            let insertItem = try prepare("""
                INSERT INTO bill_items(
                    bill_id, customer, employee, model, quantity, color_count,
                    unit_price_milli_yuan, employee_wage_milli_yuan
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
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
                   existing.customer.caseInsensitiveCompare(row.customer) == .orderedSame,
                   let historicalPrice = existing.unitPriceMilliYuan {
                    unitPrice = historicalPrice
                } else if let currentPrice = customerPrices[row.customer.lowercased()] {
                    unitPrice = currentPrice
                } else {
                    throw DatabaseError.stepFailed("客户“\(row.customer)”尚未设置加工单价，请先到客户管理页设置。")
                }

                let employeeWage: Int64
                if let existing,
                   existing.employee.caseInsensitiveCompare(row.employee) == .orderedSame,
                   let historicalWage = existing.employeeWageMilliYuan {
                    employeeWage = historicalWage
                } else if let currentWage = employeeWages[row.employee.lowercased()] {
                    employeeWage = currentWage
                } else {
                    throw DatabaseError.stepFailed("员工“\(row.employee)”尚未设置工资单价，请先到员工管理页设置后才能提交。")
                }

                guard MoneyMath.multiply(unitPrice, quantity: row.quantityValue ?? 0, colorCount: row.colorCount) != nil else {
                    throw DatabaseError.stepFailed("客户“\(row.customer)”的加工费金额超出可支持范围。")
                }
                guard MoneyMath.multiply(employeeWage, quantity: row.quantityValue ?? 0, colorCount: row.colorCount) != nil else {
                    throw DatabaseError.stepFailed("员工“\(row.employee)”的工资金额超出可支持范围。")
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
                    sqlite3_bind_int64(updateItem, 7, employeeWage)
                    sqlite3_bind_int64(updateItem, 8, existing.id)
                    sqlite3_bind_int64(updateItem, 9, billID)
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
                    sqlite3_bind_int64(insertItem, 8, employeeWage)
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

    func deleteBill(date: Date) throws {
        guard db != nil else { throw DatabaseError.openFailed("数据库未打开") }
        let billDate = DateKey.string(from: date)

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            var billID: Int64?
            try withStatement("SELECT id FROM bills WHERE bill_date = ? LIMIT 1;") { statement in
                try bindText(billDate, at: 1, in: statement)
                if sqlite3_step(statement) == SQLITE_ROW {
                    billID = sqlite3_column_int64(statement, 0)
                }
            }
            guard let billID else {
                throw DatabaseError.stepFailed("该日期没有正式账单。")
            }

            var hasSettledItems = false
            try withStatement("""
                SELECT 1 FROM bill_items
                WHERE bill_id = ? AND settlement_batch_id IS NOT NULL
                LIMIT 1;
                """) { statement in
                sqlite3_bind_int64(statement, 1, billID)
                if sqlite3_step(statement) == SQLITE_ROW {
                    hasSettledItems = true
                }
            }
            guard !hasSettledItems else {
                throw DatabaseError.stepFailed("该账单包含已结清流水，不能删除。请先撤销对应结清批次。")
            }

            try withStatement("DELETE FROM bill_items WHERE bill_id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, billID)
                try stepDone(statement)
            }
            try withStatement("DELETE FROM drafts WHERE bill_date = ?;") { statement in
                try bindText(billDate, at: 1, in: statement)
                try stepDone(statement)
            }
            try withStatement("DELETE FROM bills WHERE id = ?;") { statement in
                sqlite3_bind_int64(statement, 1, billID)
                try stepDone(statement)
            }

            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
    // MARK: - Settlement

    func createSettlementBatch(
        itemIDs: [Int64],
        settlementDate: Date,
        actualAmountMilliYuan: Int64,
        note: String
    ) throws -> SettlementBatch {
        guard let db else { throw DatabaseError.openFailed("数据库未打开") }
        let uniqueIDs = Array(Set(itemIDs)).sorted()
        guard !uniqueIDs.isEmpty else { throw DatabaseError.stepFailed("请选择要结清的流水。") }
        guard actualAmountMilliYuan >= 0 else { throw DatabaseError.stepFailed("实际结款金额不能为负数。") }

        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
            var selected: [(id: Int64, customer: String, price: Int64, quantity: Int64, color: Int64, batch: Int64?)] = []
            try withStatement("""
                SELECT id, customer, unit_price_milli_yuan, quantity, color_count, settlement_batch_id
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
            let mode = try customerSettlementMode(named: customer)
            guard mode == .batch else {
                throw DatabaseError.stepFailed("该客户采用按年回款，不能使用清账管理。")
            }
            guard !selected.contains(where: { $0.price <= 0 }) else {
                throw DatabaseError.stepFailed("部分流水尚未设置加工单价，不能结清。")
            }

            var receivable: Int64 = 0
            for row in selected {
                guard let amount = MoneyMath.multiply(row.price, quantity: Int(row.quantity), colorCount: Int(row.color)) else {
                    throw DatabaseError.stepFailed("所选流水金额超出可支持范围。")
                }
                let (sum, overflow) = receivable.addingReportingOverflow(amount)
                guard !overflow, sum <= MoneyMath.maxMilliYuan else {
                    throw DatabaseError.stepFailed("所选流水的应收金额超出可支持范围。")
                }
                receivable = sum
            }
            guard actualAmountMilliYuan <= receivable else {
                throw DatabaseError.stepFailed("实际结款金额不能超过所选流水的应收金额，客户不允许形成预存款。")
            }

            let day = DateKey.string(from: settlementDate)
            let batchNo = try nextDocumentNumber(
                table: "settlement_batches",
                column: "batch_no",
                prefix: "QZ-\(day.replacingOccurrences(of: "-", with: ""))-"
            )

            let createdAt = Date().timeIntervalSince1970
            try withStatement("""
                INSERT INTO settlement_batches(
                    batch_no, customer, settlement_date, receivable_milli_yuan,
                    actual_amount_milli_yuan, note, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """) { statement in
                try bindText(batchNo, at: 1, in: statement)
                try bindText(customer, at: 2, in: statement)
                try bindText(day, at: 3, in: statement)
                sqlite3_bind_int64(statement, 4, receivable)
                sqlite3_bind_int64(statement, 5, actualAmountMilliYuan)
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
                receivableMilliYuan: receivable,
                actualAmountMilliYuan: actualAmountMilliYuan,
                note: String(note.prefix(200)),
                createdAt: Date(timeIntervalSince1970: createdAt),
                revokedAt: nil
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func customerSettlementMode(named customer: String) throws -> CustomerSettlementMode {
        try withStatement("""
            SELECT settlement_mode FROM customers
            WHERE name = ? COLLATE NOCASE LIMIT 1;
            """) { statement in
            try bindText(customer, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.stepFailed("客户“\(customer)”的档案不存在。")
            }
            return CustomerSettlementMode.parse(text(column: 0, statement: statement)) ?? .batch
        }
    }

    private func nextDocumentNumber(table: String, column: String, prefix: String) throws -> String {
        var sequence = 1
        try withStatement("SELECT COUNT(*) FROM \(table) WHERE \(column) LIKE ?;") { statement in
            try bindText(prefix + "%", at: 1, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                sequence = Int(sqlite3_column_int64(statement, 0)) + 1
            }
        }
        var candidate = "\(prefix)\(String(format: "%03d", sequence))"
        while try documentNumberExists(table: table, column: column, value: candidate) {
            sequence += 1
            candidate = "\(prefix)\(String(format: "%03d", sequence))"
        }
        return candidate
    }

    private func documentNumberExists(table: String, column: String, value: String) throws -> Bool {
        try withStatement("SELECT 1 FROM \(table) WHERE \(column) = ? LIMIT 1;") { statement in
            try bindText(value, at: 1, in: statement)
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

    func loadSettlementBatches(includeRevoked: Bool = true) throws -> [SettlementBatch] {
        let filter = includeRevoked ? "" : "WHERE revoked_at IS NULL"
        let statement = try prepare("""
            SELECT id, batch_no, customer, settlement_date, receivable_milli_yuan,
                   actual_amount_milli_yuan, note, created_at, revoked_at
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
                    receivableMilliYuan: sqlite3_column_int64(statement, 4),
                    actualAmountMilliYuan: sqlite3_column_int64(statement, 5),
                    note: text(column: 6, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7)),
                    revokedAt: revokedAt
                )
            )
        }
        return result
    }

    // MARK: - Customer receipts

    func createCustomerReceipt(
        customer: String,
        receiptDate: Date,
        amountMilliYuan: Int64,
        note: String
    ) throws -> CustomerReceipt {
        guard amountMilliYuan > 0 else { throw DatabaseError.stepFailed("客户回款金额必须大于 0。") }
        guard amountMilliYuan <= MoneyMath.maxMilliYuan else { throw DatabaseError.stepFailed("客户回款金额超出可支持范围。") }
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let mode = try customerSettlementMode(named: customer)
            guard mode == .annual else {
                throw DatabaseError.stepFailed("该客户采用按批结清，不能登记客户回款。")
            }
            let day = DateKey.string(from: receiptDate)
            let outstanding = try customerOutstandingMilliYuan(customer: customer, through: day)
            guard amountMilliYuan <= outstanding else {
                throw DatabaseError.stepFailed("回款金额不能超过该客户截至 \(day) 的未收加工费 \(MoneyText.yuan(outstanding))。")
            }
            let receiptNo = try nextDocumentNumber(
                table: "customer_receipts",
                column: "receipt_no",
                prefix: "HK-\(day.replacingOccurrences(of: "-", with: ""))-"
            )
            let createdAt = Date().timeIntervalSince1970
            try withStatement("""
                INSERT INTO customer_receipts(
                    receipt_no, customer, amount_milli_yuan, receipt_date, note, created_at
                ) VALUES (?, ?, ?, ?, ?, ?);
                """) { statement in
                try bindText(receiptNo, at: 1, in: statement)
                try bindText(customer, at: 2, in: statement)
                sqlite3_bind_int64(statement, 3, amountMilliYuan)
                try bindText(day, at: 4, in: statement)
                try bindText(String(note.prefix(200)), at: 5, in: statement)
                sqlite3_bind_double(statement, 6, createdAt)
                try stepDone(statement)
            }
            let receiptID = lastInsertID
            try execute("COMMIT;")
            return CustomerReceipt(
                id: receiptID,
                receiptNo: receiptNo,
                customer: customer,
                amountMilliYuan: amountMilliYuan,
                receiptDate: receiptDate,
                note: String(note.prefix(200)),
                createdAt: Date(timeIntervalSince1970: createdAt),
                revokedAt: nil
            )
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func customerOutstandingMilliYuan(customer: String, through day: String) throws -> Int64 {
        var receivable: Int64 = 0
        try withStatement("""
            SELECT COALESCE(SUM(
                CASE
                    WHEN b.bill_date <= ? AND i.unit_price_milli_yuan IS NOT NULL
                    THEN i.unit_price_milli_yuan * i.quantity * i.color_count
                    ELSE 0
                END
            ), 0)
            FROM bill_items i
            JOIN bills b ON b.id = i.bill_id
            WHERE i.customer = ? COLLATE NOCASE;
            """) { statement in
            try bindText(day, at: 1, in: statement)
            try bindText(customer, at: 2, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                receivable = sqlite3_column_int64(statement, 0)
            }
        }
        var paid: Int64 = 0
        try withStatement("""
            SELECT COALESCE(SUM(amount_milli_yuan), 0)
            FROM customer_receipts
            WHERE customer = ? COLLATE NOCASE
              AND revoked_at IS NULL
              AND receipt_date <= ?;
            """) { statement in
            try bindText(customer, at: 1, in: statement)
            try bindText(day, at: 2, in: statement)
            if sqlite3_step(statement) == SQLITE_ROW {
                paid = sqlite3_column_int64(statement, 0)
            }
        }
        return max(0, receivable - paid)
    }

    func revokeCustomerReceipt(id: Int64) throws {
        let statement = try prepare("""
            UPDATE customer_receipts SET revoked_at = ?
            WHERE id = ? AND revoked_at IS NULL;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, id)
        try stepDone(statement)
        guard sqlite3_changes(db) == 1 else {
            throw DatabaseError.stepFailed("该客户回款不存在或已撤销。")
        }
    }

    func loadCustomerReceipts(includeRevoked: Bool = true) throws -> [CustomerReceipt] {
        let filter = includeRevoked ? "" : "WHERE revoked_at IS NULL"
        let statement = try prepare("""
            SELECT id, receipt_no, customer, amount_milli_yuan, receipt_date, note, created_at, revoked_at
            FROM customer_receipts
            \(filter)
            ORDER BY receipt_date DESC, id DESC;
            """)
        defer { sqlite3_finalize(statement) }
        var result: [CustomerReceipt] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let day = DateKey.date(from: text(column: 4, statement: statement)) else { continue }
            let revokedAt = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            result.append(
                CustomerReceipt(
                    id: sqlite3_column_int64(statement, 0),
                    receiptNo: text(column: 1, statement: statement),
                    customer: text(column: 2, statement: statement),
                    amountMilliYuan: sqlite3_column_int64(statement, 3),
                    receiptDate: day,
                    note: text(column: 5, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
                    revokedAt: revokedAt
                )
            )
        }
        return result
    }

    // MARK: - Employee payments

    func createEmployeePayment(
        employee: String,
        paymentDate: Date,
        amountMilliYuan: Int64,
        note: String
    ) throws -> EmployeePayment {
        guard amountMilliYuan > 0 else { throw DatabaseError.stepFailed("工资发放金额必须大于 0。") }
        guard amountMilliYuan <= MoneyMath.maxMilliYuan else { throw DatabaseError.stepFailed("工资发放金额超出可支持范围。") }
        try withStatement("SELECT 1 FROM employees WHERE name = ? COLLATE NOCASE LIMIT 1;") { statement in
            try bindText(employee, at: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw DatabaseError.stepFailed("员工“\(employee)”的档案不存在。")
            }
        }
        let day = DateKey.string(from: paymentDate)
        let paymentNo = try nextDocumentNumber(
            table: "employee_payments",
            column: "payment_no",
            prefix: "GZ-\(day.replacingOccurrences(of: "-", with: ""))-"
        )
        let createdAt = Date().timeIntervalSince1970
        try withStatement("""
            INSERT INTO employee_payments(
                payment_no, employee, amount_milli_yuan, payment_date, note, created_at
            ) VALUES (?, ?, ?, ?, ?, ?);
            """) { statement in
            try bindText(paymentNo, at: 1, in: statement)
            try bindText(employee, at: 2, in: statement)
            sqlite3_bind_int64(statement, 3, amountMilliYuan)
            try bindText(day, at: 4, in: statement)
            try bindText(String(note.prefix(200)), at: 5, in: statement)
            sqlite3_bind_double(statement, 6, createdAt)
            try stepDone(statement)
        }
        return EmployeePayment(
            id: lastInsertID,
            paymentNo: paymentNo,
            employee: employee,
            amountMilliYuan: amountMilliYuan,
            paymentDate: paymentDate,
            note: String(note.prefix(200)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            revokedAt: nil
        )
    }

    func revokeEmployeePayment(id: Int64) throws {
        let statement = try prepare("""
            UPDATE employee_payments SET revoked_at = ?
            WHERE id = ? AND revoked_at IS NULL;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(statement, 2, id)
        try stepDone(statement)
        guard sqlite3_changes(db) == 1 else {
            throw DatabaseError.stepFailed("该工资发放记录不存在或已撤销。")
        }
    }

    func loadEmployeePayments(includeRevoked: Bool = true) throws -> [EmployeePayment] {
        let filter = includeRevoked ? "" : "WHERE revoked_at IS NULL"
        let statement = try prepare("""
            SELECT id, payment_no, employee, amount_milli_yuan, payment_date, note, created_at, revoked_at
            FROM employee_payments
            \(filter)
            ORDER BY payment_date DESC, id DESC;
            """)
        defer { sqlite3_finalize(statement) }
        var result: [EmployeePayment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let day = DateKey.date(from: text(column: 4, statement: statement)) else { continue }
            let revokedAt = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            result.append(
                EmployeePayment(
                    id: sqlite3_column_int64(statement, 0),
                    paymentNo: text(column: 1, statement: statement),
                    employee: text(column: 2, statement: statement),
                    amountMilliYuan: sqlite3_column_int64(statement, 3),
                    paymentDate: day,
                    note: text(column: 5, statement: statement),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6)),
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
            let isV15 = data.schemaVersion >= 3

            for entry in data.customers {
                try withStatement("""
                    INSERT INTO customers(
                        name, unit_price_milli_yuan, settlement_mode, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        unit_price_milli_yuan = excluded.unit_price_milli_yuan,
                        settlement_mode = excluded.settlement_mode,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at;
                    """) { statement in
                    let createdAt = entry.createdAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? now
                    let updatedAt = entry.updatedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? createdAt
                    try bindText(entry.name, at: 1, in: statement)
                    bindOptionalInt64(isV15 ? entry.unitPriceMilliYuan : nil, at: 2, in: statement)
                    try bindText((CustomerSettlementMode.parse(entry.settlementMode) ?? .batch).rawValue, at: 3, in: statement)
                    sqlite3_bind_double(statement, 4, createdAt)
                    sqlite3_bind_double(statement, 5, updatedAt)
                    try stepDone(statement)
                }
            }

            for entry in data.employees {
                try withStatement("""
                    INSERT INTO employees(name, wage_milli_yuan, created_at, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(name) DO UPDATE SET
                        wage_milli_yuan = excluded.wage_milli_yuan,
                        created_at = excluded.created_at,
                        updated_at = excluded.updated_at;
                    """) { statement in
                    let createdAt = entry.createdAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? now
                    let updatedAt = entry.updatedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970 ?? createdAt
                    try bindText(entry.name, at: 1, in: statement)
                    bindOptionalInt64(isV15 ? entry.wageMilliYuan : nil, at: 2, in: statement)
                    sqlite3_bind_double(statement, 3, createdAt)
                    sqlite3_bind_double(statement, 4, updatedAt)
                    try stepDone(statement)
                }
            }

            var batchIDsByNumber: [String: Int64] = [:]
            var activeBatchNumbers: Set<String> = []
            for batch in data.settlementBatches ?? [] {
                let receivable = isV15
                    ? (batch.receivableMilliYuan ?? 0)
                    : Int64(batch.receivableCents ?? 0) * 10
                let actual = isV15
                    ? (batch.actualAmountMilliYuan ?? 0)
                    : Int64(batch.actualAmountCents ?? 0) * 10
                try withStatement("""
                    INSERT INTO settlement_batches(
                        batch_no, customer, settlement_date, receivable_milli_yuan,
                        actual_amount_milli_yuan, note, created_at, revoked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(batch_no) DO UPDATE SET
                        customer = excluded.customer,
                        settlement_date = excluded.settlement_date,
                        receivable_milli_yuan = excluded.receivable_milli_yuan,
                        actual_amount_milli_yuan = excluded.actual_amount_milli_yuan,
                        note = excluded.note,
                        created_at = excluded.created_at,
                        revoked_at = excluded.revoked_at;
                    """) { statement in
                    let createdAt = CloudDate.parse(batch.createdAt)?.timeIntervalSince1970 ?? now
                    let revokedAt = batch.revokedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970
                    try bindText(batch.batchNo, at: 1, in: statement)
                    try bindText(batch.customer, at: 2, in: statement)
                    try bindText(batch.settlementDate, at: 3, in: statement)
                    sqlite3_bind_int64(statement, 4, receivable)
                    sqlite3_bind_int64(statement, 5, actual)
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

            for receipt in data.customerReceipts ?? [] {
                let createdAt = CloudDate.parse(receipt.createdAt)?.timeIntervalSince1970 ?? now
                let revokedAt = receipt.revokedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970
                try withStatement("""
                    INSERT INTO customer_receipts(
                        receipt_no, customer, amount_milli_yuan, receipt_date,
                        note, created_at, revoked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(receipt_no) DO UPDATE SET
                        customer = excluded.customer,
                        amount_milli_yuan = excluded.amount_milli_yuan,
                        receipt_date = excluded.receipt_date,
                        note = excluded.note,
                        created_at = excluded.created_at,
                        revoked_at = excluded.revoked_at;
                    """) { statement in
                    try bindText(receipt.receiptNo, at: 1, in: statement)
                    try bindText(receipt.customer, at: 2, in: statement)
                    sqlite3_bind_int64(statement, 3, receipt.amountMilliYuan)
                    try bindText(receipt.receiptDate, at: 4, in: statement)
                    try bindText(receipt.note, at: 5, in: statement)
                    sqlite3_bind_double(statement, 6, createdAt)
                    if let revokedAt {
                        sqlite3_bind_double(statement, 7, revokedAt)
                    } else {
                        sqlite3_bind_null(statement, 7)
                    }
                    try stepDone(statement)
                }
            }

            for payment in data.employeePayments ?? [] {
                let createdAt = CloudDate.parse(payment.createdAt)?.timeIntervalSince1970 ?? now
                let revokedAt = payment.revokedAt.flatMap(CloudDate.parse)?.timeIntervalSince1970
                try withStatement("""
                    INSERT INTO employee_payments(
                        payment_no, employee, amount_milli_yuan, payment_date,
                        note, created_at, revoked_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(payment_no) DO UPDATE SET
                        employee = excluded.employee,
                        amount_milli_yuan = excluded.amount_milli_yuan,
                        payment_date = excluded.payment_date,
                        note = excluded.note,
                        created_at = excluded.created_at,
                        revoked_at = excluded.revoked_at;
                    """) { statement in
                    try bindText(payment.paymentNo, at: 1, in: statement)
                    try bindText(payment.employee, at: 2, in: statement)
                    sqlite3_bind_int64(statement, 3, payment.amountMilliYuan)
                    try bindText(payment.paymentDate, at: 4, in: statement)
                    try bindText(payment.note, at: 5, in: statement)
                    sqlite3_bind_double(statement, 6, createdAt)
                    if let revokedAt {
                        sqlite3_bind_double(statement, 7, revokedAt)
                    } else {
                        sqlite3_bind_null(statement, 7)
                    }
                    try stepDone(statement)
                }
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

                try withStatement("DELETE FROM bill_items WHERE bill_id = ?;") { statement in
                    sqlite3_bind_int64(statement, 1, billID)
                    try stepDone(statement)
                }
                _ = date

                try withStatement("""
                    INSERT INTO bill_items(
                        bill_id, customer, employee, model, quantity, color_count,
                        unit_price_milli_yuan, employee_wage_milli_yuan, settlement_batch_id
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
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
                        bindOptionalInt64(isV15 ? item.unitPriceMilliYuan : nil, at: 7, in: insertItem)
                        bindOptionalInt64(isV15 ? item.employeeWageMilliYuan : nil, at: 8, in: insertItem)
                        if let batchNo = item.settlementBatchNo,
                           activeBatchNumbers.contains(batchNo),
                           let batchID = batchIDsByNumber[batchNo] {
                            sqlite3_bind_int64(insertItem, 9, batchID)
                        } else {
                            sqlite3_bind_null(insertItem, 9)
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