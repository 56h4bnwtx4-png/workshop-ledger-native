import Foundation

struct Customer: Identifiable, Hashable {
    let id: Int64
    var name: String
    var unitPriceCents: Int64?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: Int64,
        name: String,
        unitPriceCents: Int64? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.unitPriceCents = unitPriceCents
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Employee: Identifiable, Hashable {
    let id: Int64
    var name: String
    var createdAt: Date
    var updatedAt: Date

    init(id: Int64, name: String, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct BillItem: Identifiable, Hashable {
    let id: Int64
    let billID: Int64
    let customer: String
    let employee: String
    let model: String
    let quantity: Int
    let colorCount: Int
    let unitPriceCents: Int64?
    let settlementBatchID: Int64?

    var workload: Int { quantity * colorCount }
    var receivableCents: Int64? {
        guard let unitPriceCents else { return nil }
        return unitPriceCents * Int64(quantity) * Int64(colorCount)
    }
    var isSettled: Bool { settlementBatchID != nil }
}

struct Bill: Identifiable, Hashable {
    let id: Int64
    let date: Date
    let submittedAt: Date
    let items: [BillItem]

    var workload: Int { items.reduce(0) { $0 + $1.workload } }
    var customerCount: Int { Set(items.map(\.customer)).count }
    var employeeCount: Int { Set(items.map(\.employee)).count }
    var receivableCents: Int64 { items.compactMap(\.receivableCents).reduce(0, +) }
    var settledCount: Int { items.filter(\.isSettled).count }
}

struct SettlementBatch: Identifiable, Hashable {
    let id: Int64
    let batchNo: String
    let customer: String
    let settlementDate: Date
    let receivableCents: Int64
    let actualAmountCents: Int64
    let note: String
    let createdAt: Date
    let revokedAt: Date?

    var differenceCents: Int64 { actualAmountCents - receivableCents }
    var isRevoked: Bool { revokedAt != nil }
}

struct DraftSummary: Identifiable, Hashable {
    let date: Date
    let updatedAt: Date
    var id: String { DateKey.string(from: date) }
}

struct EntryRow: Identifiable, Codable, Hashable {
    var id: UUID
    var customer: String
    var employee: String
    var model: String
    var quantity: String
    var colorCount: Int
    var existingItemID: Int64? = nil
    var storedUnitPriceCents: Int64? = nil
    var settlementBatchID: Int64? = nil

    static func empty(customer: String = "", employee: String = "") -> EntryRow {
        EntryRow(
            id: UUID(),
            customer: customer,
            employee: employee,
            model: "",
            quantity: "",
            colorCount: 1
        )
    }

    var quantityValue: Int? {
        guard let value = Int(quantity), value > 0 else { return nil }
        return value
    }

    var isLocked: Bool { settlementBatchID != nil }

    var isCompletelyEmpty: Bool {
        customer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && employee.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DraftPayload: Codable {
    var rows: [EntryRow]
}

struct QueryRecord: Identifiable, Hashable {
    let id: String
    let billID: Int64
    let itemID: Int64
    let date: Date
    let employee: String
    let customer: String
    let model: String
    let quantity: Int
    let colorCount: Int
    let workload: Int
}

enum DateKey {
    private static let keyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月d日"
        return formatter
    }()

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static func string(from date: Date) -> String {
        keyFormatter.string(from: date)
    }

    static func date(from string: String) -> Date? {
        keyFormatter.date(from: string)
    }

    static func display(_ date: Date) -> String {
        displayFormatter.string(from: date)
    }

    static func filenameTimestamp(_ date: Date = Date()) -> String {
        filenameFormatter.string(from: date)
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }
}

enum MoneyText {
    static func parseCents(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: "")
        guard !trimmed.isEmpty, !trimmed.contains("-") else { return nil }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let wholeText = parts.isEmpty ? "0" : String(parts[0])
        let whole = wholeText.isEmpty ? "0" : wholeText
        guard whole.allSatisfy(\.isNumber), whole.count <= 9 else { return nil }
        let fractionText: String
        if parts.count == 2 {
            guard parts[1].allSatisfy(\.isNumber), parts[1].count <= 2 else { return nil }
            fractionText = String(parts[1]).padding(toLength: 2, withPad: "0", startingAt: 0)
        } else {
            fractionText = "00"
        }
        guard let wholeValue = Int64(whole), let fractionValue = Int64(fractionText) else { return nil }
        return wholeValue * 100 + fractionValue
    }

    static func yuan(_ cents: Int64?, empty: String = "未设置") -> String {
        guard let cents else { return empty }
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return "\(sign)¥\(absolute / 100).\(String(format: "%02lld", absolute % 100))"
    }

    static func plainYuan(_ cents: Int64?) -> String {
        guard let cents else { return "" }
        let sign = cents < 0 ? "-" : ""
        let absolute = abs(cents)
        return "\(sign)\(absolute / 100).\(String(format: "%02lld", absolute % 100))"
    }
}

extension Array where Element == EntryRow {
    func normalizedForSubmission() -> [EntryRow] {
        map { row in
            var copy = row
            copy.customer = copy.customer.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.employee = copy.employee.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.model = copy.model.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.quantity = copy.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.colorCount = Swift.min(5, Swift.max(1, copy.colorCount))
            return copy
        }
        .filter { !$0.isCompletelyEmpty }
    }
}
