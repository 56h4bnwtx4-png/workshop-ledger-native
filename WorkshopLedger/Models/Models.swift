import Foundation

enum CustomerSettlementMode: String, Codable, CaseIterable, Identifiable {
    case batch = "batch"
    case annual = "annual"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .batch: return "按批结清"
        case .annual: return "按年回款"
        }
    }

    var shortDescription: String {
        switch self {
        case .batch: return "通过清账管理按流水批次结款"
        case .annual: return "通过客户回款按年度登记到账"
        }
    }

    static func parse(_ value: String?) -> CustomerSettlementMode? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "batch", "batch_clear", "clear": return .batch
        case "annual", "annual_receipt", "receipt": return .annual
        default: return nil
        }
    }
}

struct Customer: Identifiable, Hashable {
    let id: Int64
    var name: String
    var unitPriceMilliYuan: Int64?
    var settlementMode: CustomerSettlementMode
    var createdAt: Date
    var updatedAt: Date

    init(
        id: Int64,
        name: String,
        unitPriceMilliYuan: Int64? = nil,
        settlementMode: CustomerSettlementMode = .batch,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.unitPriceMilliYuan = unitPriceMilliYuan
        self.settlementMode = settlementMode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct Employee: Identifiable, Hashable {
    let id: Int64
    var name: String
    var wageMilliYuan: Int64?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: Int64,
        name: String,
        wageMilliYuan: Int64? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.wageMilliYuan = wageMilliYuan
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
    let unitPriceMilliYuan: Int64?
    let employeeWageMilliYuan: Int64?
    let settlementBatchID: Int64?

    var workload: Int { quantity * colorCount }

    var receivableMilliYuan: Int64? {
        guard let unitPriceMilliYuan else { return nil }
        return MoneyMath.multiply(unitPriceMilliYuan, quantity: quantity, colorCount: colorCount)
    }

    var wageMilliYuan: Int64? {
        guard let employeeWageMilliYuan else { return nil }
        return MoneyMath.multiply(employeeWageMilliYuan, quantity: quantity, colorCount: colorCount)
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
    var receivableMilliYuan: Int64 { items.compactMap(\.receivableMilliYuan).reduce(0, +) }
    var wageMilliYuan: Int64 { items.compactMap(\.wageMilliYuan).reduce(0, +) }
    var settledCount: Int { items.filter(\.isSettled).count }
}

struct SettlementBatch: Identifiable, Hashable {
    let id: Int64
    let batchNo: String
    let customer: String
    let settlementDate: Date
    let receivableMilliYuan: Int64
    let actualAmountMilliYuan: Int64
    let note: String
    let createdAt: Date
    let revokedAt: Date?

    var differenceMilliYuan: Int64 { actualAmountMilliYuan - receivableMilliYuan }
    var isRevoked: Bool { revokedAt != nil }
}

struct CustomerReceipt: Identifiable, Hashable {
    let id: Int64
    let receiptNo: String
    let customer: String
    let amountMilliYuan: Int64
    let receiptDate: Date
    let note: String
    let createdAt: Date
    let revokedAt: Date?

    var isRevoked: Bool { revokedAt != nil }
}

struct EmployeePayment: Identifiable, Hashable {
    let id: Int64
    let paymentNo: String
    let employee: String
    let amountMilliYuan: Int64
    let paymentDate: Date
    let note: String
    let createdAt: Date
    let revokedAt: Date?

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
    var storedUnitPriceMilliYuan: Int64? = nil
    var storedEmployeeWageMilliYuan: Int64? = nil
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

    var hasEntryData: Bool {
        !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !quantity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

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
    let unitPriceMilliYuan: Int64?
    let employeeWageMilliYuan: Int64?
    let receivableMilliYuan: Int64?
    let wageMilliYuan: Int64?
    let settlementBatchID: Int64?
}

struct FactoryAnnualSettlement: Equatable {
    let year: Int
    let receivableMilliYuan: Int64
    let receivableCollectedMilliYuan: Int64
    let payableMilliYuan: Int64
    let wagesPaidMilliYuan: Int64

    var bookDifferenceMilliYuan: Int64 { receivableMilliYuan - payableMilliYuan }
    var cashDifferenceMilliYuan: Int64 { receivableCollectedMilliYuan - wagesPaidMilliYuan }
}

struct CustomerAnnualSettlement: Equatable {
    let year: Int
    let customer: String
    let mode: CustomerSettlementMode
    let annualReceivableMilliYuan: Int64
    let annualPaymentMilliYuan: Int64
    let annualBatchPaymentMilliYuan: Int64
    let annualReceiptPaymentMilliYuan: Int64
    let outstandingAtYearEndMilliYuan: Int64
}

struct EmployeeAnnualSettlement: Equatable {
    let year: Int
    let employee: String
    let annualPayableMilliYuan: Int64
    let annualPaidMilliYuan: Int64
    let balanceAtYearEndMilliYuan: Int64
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

enum MoneyMath {
    static let maxMilliYuan: Int64 = 900_000_000_000

    static func multiply(_ unit: Int64, quantity: Int, colorCount: Int) -> Int64? {
        guard unit >= 0, quantity > 0, colorCount > 0 else { return nil }
        let (quantityProduct, quantityOverflow) = unit.multipliedReportingOverflow(by: Int64(quantity))
        guard !quantityOverflow else { return nil }
        let (result, colorOverflow) = quantityProduct.multipliedReportingOverflow(by: Int64(colorCount))
        guard !colorOverflow, result <= maxMilliYuan else { return nil }
        return result
    }
}

enum MoneyText {
    static func parseMilliYuan(_ value: String) -> Int64? {
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
            guard parts[1].allSatisfy(\.isNumber), parts[1].count <= 3 else { return nil }
            fractionText = String(parts[1]).padding(toLength: 3, withPad: "0", startingAt: 0)
        } else {
            fractionText = "000"
        }
        guard let wholeValue = Int64(whole), let fractionValue = Int64(fractionText) else { return nil }
        let (wholePart, overflow) = wholeValue.multipliedReportingOverflow(by: 1_000)
        guard !overflow else { return nil }
        let (result, addOverflow) = wholePart.addingReportingOverflow(fractionValue)
        guard !addOverflow, result <= MoneyMath.maxMilliYuan else { return nil }
        return result
    }

    static func yuan(_ milliYuan: Int64?, empty: String = "未设置") -> String {
        guard let milliYuan else { return empty }
        let sign = milliYuan < 0 ? "-" : ""
        let absolute = abs(milliYuan)
        return "\(sign)¥\(absolute / 1_000).\(String(format: "%03lld", absolute % 1_000))"
    }

    static func plainYuan(_ milliYuan: Int64?) -> String {
        guard let milliYuan else { return "" }
        let sign = milliYuan < 0 ? "-" : ""
        let absolute = abs(milliYuan)
        return "\(sign)\(absolute / 1_000).\(String(format: "%03lld", absolute % 1_000))"
    }
}

extension Array where Element == EntryRow {
    func matchesBillItems(_ items: [BillItem]) -> Bool {
        let rows = normalizedForSubmission().filter(\.hasEntryData)
        guard rows.count == items.count else { return false }
        return zip(rows, items).allSatisfy { row, item in
            row.customer == item.customer
                && row.employee == item.employee
                && row.model == item.model
                && row.quantityValue == item.quantity
                && row.colorCount == item.colorCount
        }
    }

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
