import SwiftUI

struct SettlementView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var customerName = ""
    @State private var selectedItemIDs: Set<Int64> = []
    @State private var showingBatchSheet = false
    @State private var activeAlert: SettlementAlert?
    @State private var statusMessage = ""

    private var rows: [SettlementRow] {
        let batches = Dictionary(uniqueKeysWithValues: store.settlementBatches.map { ($0.id, $0) })
        return store.bills.flatMap { bill in
            bill.items
                .filter { $0.customer == customerName }
                .map { item in
                    SettlementRow(
                        date: bill.date,
                        item: item,
                        batch: item.settlementBatchID.flatMap { batches[$0] }
                    )
                }
        }
        .sorted {
            if $0.date == $1.date { return $0.item.id > $1.item.id }
            return $0.date > $1.date
        }
    }

    private var batchCustomerNames: [String] {
        store.customersUsingBatchSettlement.map(\.name)
    }

    private var activeBatches: [SettlementBatch] {
        store.settlementBatches
            .filter { $0.customer == customerName && !$0.isRevoked }
            .sorted { $0.id > $1.id }
    }

    private var selectedRows: [SettlementRow] {
        rows.filter { selectedItemIDs.contains($0.id) }
    }

    private var selectedReceivable: Int64 {
        selectedRows.compactMap(\.receivableMilliYuan).reduce(0, +)
    }

    private var unsettledRows: [SettlementRow] {
        rows.filter { !$0.isSettled }
    }

    private var settledRows: [SettlementRow] {
        rows.filter(\.isSettled)
    }

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "清账管理",
                brandSubtitle: "Settlement",
                brandIcon: "checkmark.seal",
                backAction: onClose
            ) {
                LocalModeBadge(text: "iOS 可结清 · Windows 只读")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeading(
                        eyebrow: "客户加工费结算",
                        title: "清账管理",
                        note: "直接查看所选客户的全部流水。同一型号可部分结清；结清后流水锁定，只能按整个批次撤销。"
                    ) {
                        PageScopeBadge(label: "当前客户", value: customerName.isEmpty ? "请选择" : customerName)
                    }

                    customerBar

                    if !statusMessage.isEmpty {
                        statusBanner
                    }

                    summaryStrip

                    batchHistory

                    selectionBar

                    ledgerTable
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 34)
            }
        }
        .onAppear(perform: ensureCustomerSelection)
        .onChange(of: store.customersUsingBatchSettlement) { _ in ensureCustomerSelection() }
        .onChange(of: customerName) { _ in
            selectedItemIDs.removeAll()
            statusMessage = ""
        }
        .sheet(isPresented: $showingBatchSheet) {
            SettlementBatchSheet(
                customer: customerName,
                rows: selectedRows,
                onCancel: { showingBatchSheet = false },
                onConfirm: { date, amount, note in
                    try store.createSettlementBatch(
                        itemIDs: selectedRows.map(\.id),
                        settlementDate: date,
                        actualAmountMilliYuan: amount,
                        note: note
                    )
                    showingBatchSheet = false
                    selectedItemIDs.removeAll()
                    statusMessage = "结清成功。相关流水已锁定，并已保存结清批次。"
                }
            )
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .error(let message):
                return Alert(
                    title: Text("无法完成清账"),
                    message: Text(message),
                    dismissButton: .default(Text("知道了"))
                )
            case .undo(let batch):
                return Alert(
                    title: Text("撤销整个结清批次？"),
                    message: Text("批次 \(batch.batchNo) 将恢复为未结清。原结款金额、日期与批次记录仍会永久保留。"),
                    primaryButton: .destructive(Text("撤销整批")) {
                        undo(batch)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private var customerBar: some View {
        Panel {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("选择客户")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("不按日期、型号或员工筛选，直接显示该客户全部流水。")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                }

                Spacer()

                Menu {
                    ForEach(batchCustomerNames, id: \.self) { name in
                        Button(name) {
                            customerName = name
                        }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "person.2")
                            .foregroundColor(AppTheme.accentDark)
                        Text(customerName.isEmpty ? "请选择客户" : customerName)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.text)
                            .lineLimit(1)
                        Spacer(minLength: 10)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 300, height: 46)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(AppTheme.line, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(batchCustomerNames.isEmpty)

                if let price = store.unitPriceMilliYuan(forCustomer: customerName) {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("当前加工单价")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(AppTheme.textFaint)
                        Text("\(MoneyText.yuan(price)) / 件·色")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(AppTheme.accentDark)
                    }
                } else if !customerName.isEmpty {
                    Text("未设置单价")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.danger)
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                        .background(AppTheme.dangerSoft)
                        .clipShape(Capsule())
                }
            }
            .padding(18)
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            settlementMetric("未结清流水", "\(unsettledRows.count)", unit: "条", primary: true)
            settlementMetric("已结清流水", "\(settledRows.count)", unit: "条", primary: false)
            settlementMetric("当前选择", "\(selectedRows.count)", unit: "条", primary: false)
            settlementMetric("所选应收", MoneyText.yuan(selectedReceivable, empty: "¥0.00"), unit: "", primary: true)
        }
    }

    private var batchHistory: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已结清批次")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Spacer()
                Text("只能整批撤销，结款记录不会删除")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textFaint)
            }

            if activeBatches.isEmpty {
                Text("当前客户还没有有效结清批次。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.surfaceSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(activeBatches) { batch in
                            batchCard(batch)
                        }
                    }
                }
            }
        }
    }

    private func batchCard(_ batch: SettlementBatch) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(batch.batchNo)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(AppTheme.accentDark)
                Spacer()
                Button {
                    activeAlert = .undo(batch)
                } label: {
                    Text("撤销整批")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.danger)
                }
                .buttonStyle(PlainButtonStyle())
            }
            HStack(spacing: 16) {
                compactAmount("应收", batch.receivableMilliYuan)
                compactAmount("实收", batch.actualAmountMilliYuan)
                compactAmount("差额", batch.differenceMilliYuan)
            }
            Text("结款日期 \(DateKey.display(batch.settlementDate))\(batch.note.isEmpty ? "" : " · \(batch.note)")")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textMuted)
                .lineLimit(1)
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        )
    }

    private func compactAmount(_ label: String, _ cents: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(AppTheme.textFaint)
            Text(MoneyText.yuan(cents))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(cents < 0 ? AppTheme.danger : AppTheme.text)
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("勾选未结清流水，组成一个结清批次")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Text("所选客户应收合计 \(MoneyText.yuan(selectedReceivable, empty: "¥0.00"))，实际结款总额可不同。")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer()
            Button {
                selectedItemIDs = Set(unsettledRows.map(\.id))
            } label: {
                Text("全选未结清")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(unsettledRows.isEmpty)

            Button {
                selectedItemIDs.removeAll()
            } label: {
                Text("清空选择")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(selectedItemIDs.isEmpty)

            Button {
                showingBatchSheet = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("结清所选流水")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(selectedRows.isEmpty)
        }
        .padding(16)
        .background(AppTheme.accentSoft.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    private var ledgerTable: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    tableHeader("", width: 44)
                    tableHeader("日期", width: 96)
                    tableHeader("型号", width: 150)
                    tableHeader("员工", width: 100)
                    tableHeader("数量", width: 64)
                    tableHeader("色数", width: 56)
                    tableHeader("单价", width: 108)
                    tableHeader("工作量", width: 78)
                    tableHeader("应收", width: 106)
                    tableHeader("状态", width: 88)
                    tableHeader("结款日期", width: 100)
                    tableHeader("实收", width: 106)
                    tableHeader("差额", width: 100)
                    tableHeader("结清批次", width: 152)
                }
                .frame(height: 42)
                .background(Color(red: 0.98, green: 0.984, blue: 0.988))

                if rows.isEmpty {
                    Text(customerName.isEmpty ? "请先选择客户。" : "该客户还没有正式流水。")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textMuted)
                        .frame(width: 1300, height: 120)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        tableRow(row, alternate: !index.isMultiple(of: 2))
                        Rectangle()
                            .fill(AppTheme.line)
                            .frame(width: 1300, height: 1)
                    }
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            )
        }
    }

    private func tableHeader(_ title: String, width: CGFloat) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(AppTheme.textMuted)
            .frame(width: width, alignment: .leading)
            .padding(.horizontal, 4)
    }

    private func tableRow(_ row: SettlementRow, alternate: Bool) -> some View {
        HStack(spacing: 0) {
            Button {
                guard !row.isSettled else { return }
                if selectedItemIDs.contains(row.id) {
                    selectedItemIDs.remove(row.id)
                } else {
                    selectedItemIDs.insert(row.id)
                }
            } label: {
                Image(systemName: row.isSettled
                      ? "lock.fill"
                      : (selectedItemIDs.contains(row.id) ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(row.isSettled ? AppTheme.textFaint : AppTheme.accent)
                    .frame(width: 36, height: 44)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(row.isSettled)
            .frame(width: 44)

            tableCell(DateKey.string(from: row.date), width: 96, mono: true)
            tableCell(row.item.model, width: 150, weight: .semibold)
            tableCell(row.item.employee, width: 100)
            tableCell(String(row.item.quantity), width: 64, align: .trailing)
            tableCell("\(row.item.colorCount) 色", width: 56)
            tableCell(MoneyText.yuan(row.item.unitPriceMilliYuan), width: 108)
            tableCell(String(row.item.workload), width: 78, align: .trailing)
            tableCell(MoneyText.yuan(row.receivableMilliYuan, empty: "—"), width: 106, weight: .semibold)
            statusCell(row)
            tableCell(row.batch.map { DateKey.display($0.settlementDate) } ?? "—", width: 100)
            tableCell(row.batch.map { MoneyText.yuan($0.actualAmountMilliYuan) } ?? "—", width: 106)
            tableCell(row.batch.map { MoneyText.yuan($0.differenceMilliYuan) } ?? "—", width: 100)
            tableCell(row.batch?.batchNo ?? "—", width: 152, mono: true)
        }
        .frame(minHeight: 44)
        .background(
            selectedItemIDs.contains(row.id)
                ? AppTheme.accentSoft.opacity(0.45)
                : (alternate ? AppTheme.surfaceSoft.opacity(0.55) : Color.white)
        )
    }

    private func tableCell(
        _ value: String,
        width: CGFloat,
        align: Alignment = .leading,
        weight: Font.Weight = .regular,
        mono: Bool = false
    ) -> some View {
        Text(value)
            .font(.system(size: 11, weight: weight, design: mono ? .monospaced : .default))
            .foregroundColor(AppTheme.textMuted)
            .lineLimit(1)
            .frame(width: width, alignment: align)
            .padding(.horizontal, 4)
    }

    private func statusCell(_ row: SettlementRow) -> some View {
        Text(row.isSettled ? "已结清" : "未结清")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(row.isSettled ? AppTheme.success : AppTheme.accentDark)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(row.isSettled ? Color(red: 0.93, green: 0.97, blue: 0.95) : AppTheme.accentSoft)
            .clipShape(Capsule())
            .frame(width: 88)
    }

    private func settlementMetric(_ label: String, _ value: String, unit: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.textFaint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: primary ? 22 : 20, weight: .heavy))
                    .foregroundColor(primary ? AppTheme.accentDark : AppTheme.text)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textMuted)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(primary ? AppTheme.accent.opacity(0.35) : AppTheme.line, lineWidth: 1)
        )
    }

    private var statusBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(AppTheme.success)
            Text(statusMessage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AppTheme.text)
            Spacer()
            Button("关闭") { statusMessage = "" }
                .buttonStyle(PlainButtonStyle())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(red: 0.93, green: 0.97, blue: 0.95))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func ensureCustomerSelection() {
        guard !batchCustomerNames.isEmpty else {
            customerName = ""
            return
        }
        if !batchCustomerNames.contains(customerName) {
            customerName = batchCustomerNames[0]
        }
    }

    private func undo(_ batch: SettlementBatch) {
        do {
            try store.revokeSettlementBatch(batch)
            selectedItemIDs.removeAll()
            statusMessage = "批次 \(batch.batchNo) 已整批撤销；原结款记录已保留。"
        } catch {
            activeAlert = .error(error.localizedDescription)
        }
    }
}

private struct SettlementRow: Identifiable {
    let date: Date
    let item: BillItem
    let batch: SettlementBatch?

    var id: Int64 { item.id }
    var isSettled: Bool { batch != nil }
    var receivableMilliYuan: Int64? { item.receivableMilliYuan }
}

private enum SettlementAlert: Identifiable {
    case error(String)
    case undo(SettlementBatch)

    var id: String {
        switch self {
        case .error(let message): return "error-\(message)"
        case .undo(let batch): return "undo-\(batch.id)"
        }
    }
}

private struct SettlementBatchSheet: View {
    let customer: String
    let rows: [SettlementRow]
    let onCancel: () -> Void
    let onConfirm: (Date, Int64, String) throws -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var settlementDate = DateKey.startOfDay(Date())
    @State private var amountText: String
    @State private var note = ""
    @State private var errorMessage = ""

    private var receivable: Int64 {
        rows.compactMap(\.receivableMilliYuan).reduce(0, +)
    }

    private var actualAmount: Int64? {
        MoneyText.parseMilliYuan(amountText)
    }

    init(
        customer: String,
        rows: [SettlementRow],
        onCancel: @escaping () -> Void,
        onConfirm: @escaping (Date, Int64, String) throws -> Void
    ) {
        self.customer = customer
        self.rows = rows
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        let total = rows.compactMap(\.receivableMilliYuan).reduce(0, +)
        _amountText = State(initialValue: MoneyText.plainYuan(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("新建结清批次")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("客户：\(customer) · 共 \(rows.count) 条流水")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            HStack(spacing: 12) {
                amountSummary("系统应收", receivable, primary: true)
                amountSummary("实际结款", actualAmount ?? 0, primary: false)
                amountSummary("差额", (actualAmount ?? 0) - receivable, primary: false)
            }

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("实际结款日期")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(AppTheme.textMuted)
                    DatePicker(
                        "结款日期",
                        selection: $settlementDate,
                        in: Date.distantPast...DateKey.startOfDay(Date()),
                        displayedComponents: .date
                    )
                    .datePickerStyle(WheelDatePickerStyle())
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "zh_CN"))
                    .frame(height: 150)
                }
                .frame(width: 240)

                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("实际结款总额（元）")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppTheme.textMuted)
                        HStack(spacing: 8) {
                            Text("¥")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppTheme.textMuted)
                            TextField("请输入实际结款总额", text: $amountText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.line, lineWidth: 1)
                        )
                        Text("实际结款不能超过系统应收，客户不允许形成预存款；差额会随批次保存。")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textFaint)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("备注（可选）")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(AppTheme.textMuted)
                        TextField("例如：现金结清、抹零", text: $note)
                            .font(.system(size: 14))
                            .padding(.horizontal, 12)
                            .frame(height: 44)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppTheme.line, lineWidth: 1)
                            )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("本批次流水")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AppTheme.textMuted)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 12) {
                                Text(DateKey.string(from: row.date))
                                    .frame(width: 90, alignment: .leading)
                                Text(row.item.model)
                                    .frame(width: 140, alignment: .leading)
                                Text(row.item.employee)
                                    .frame(width: 90, alignment: .leading)
                                Text("\(row.item.quantity) × \(row.item.colorCount) 色")
                                    .frame(width: 90, alignment: .leading)
                                Spacer()
                                Text(MoneyText.yuan(row.receivableMilliYuan, empty: "—"))
                                    .fontWeight(.semibold)
                            }
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                            .frame(height: 34)
                            Rectangle().fill(AppTheme.line).frame(height: 1)
                        }
                    }
                }
                .frame(maxHeight: 170)
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.danger)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("确认结清并锁定") {
                    guard let actualAmount else {
                        errorMessage = "请输入有效的实际结款总额，最多三位小数。"
                        return
                    }
                    guard actualAmount <= receivable else {
                        errorMessage = "实际结款金额不能超过系统应收，客户不允许形成预存款。"
                        return
                    }
                    do {
                        try onConfirm(settlementDate, actualAmount, note)
                        presentationMode.wrappedValue.dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(rows.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 640)
        .background(AppTheme.background)
    }

    private func amountSummary(_ label: String, _ cents: Int64, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.textFaint)
            Text(MoneyText.yuan(cents))
                .font(.system(size: 18, weight: .heavy))
                .foregroundColor(cents < 0 ? AppTheme.danger : (primary ? AppTheme.accentDark : AppTheme.text))
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(primary ? AppTheme.accent.opacity(0.3) : AppTheme.line, lineWidth: 1)
        )
    }
}
