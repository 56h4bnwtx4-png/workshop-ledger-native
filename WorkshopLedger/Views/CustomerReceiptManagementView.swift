import SwiftUI

struct CustomerReceiptManagementView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var customerName = ""
    @State private var amountText = ""
    @State private var receiptDate = DateKey.startOfDay(Date())
    @State private var note = ""
    @State private var errorMessage = ""
    @State private var statusMessage = ""
    @State private var revokeTarget: CustomerReceipt?

    private var annualCustomers: [Customer] {
        store.customersUsingAnnualReceipts
    }

    private var receipts: [CustomerReceipt] {
        store.customerReceipts
            .filter { $0.customer.caseInsensitiveCompare(customerName) == .orderedSame }
            .sorted {
                if $0.receiptDate == $1.receiptDate { return $0.id > $1.id }
                return $0.receiptDate > $1.receiptDate
            }
    }

    private var outstanding: Int64 {
        guard !customerName.isEmpty else { return 0 }
        return store.customerOutstandingMilliYuan(customer: customerName)
    }

    private var annualReceived: Int64 {
        receipts.filter { !$0.isRevoked }.reduce(0) { $0 + $1.amountMilliYuan }
    }

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "客户回款",
                brandSubtitle: "Customer Receipts",
                brandIcon: "banknote",
                backAction: onClose
            ) {
                LocalModeBadge(text: "按年回款客户专用")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeading(
                        eyebrow: "客户年度到账",
                        title: "客户回款",
                        note: "只登记客户实际支付的加工费，不绑定具体流水。允许分次回款，但不能超过当时未收加工费。"
                    ) {
                        PageScopeBadge(label: "当前客户", value: customerName.isEmpty ? "请选择" : customerName)
                    }

                    if annualCustomers.isEmpty {
                        emptyAnnualCustomerPanel
                    } else {
                        HStack(alignment: .top, spacing: 18) {
                            entryPanel
                            balancePanel
                                .frame(width: 330)
                        }
                    }

                    if !statusMessage.isEmpty {
                        statusBanner(statusMessage, success: true)
                    }
                    if !errorMessage.isEmpty {
                        statusBanner(errorMessage, success: false)
                    }

                    receiptHistory
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 34)
            }
        }
        .onAppear(perform: ensureCustomerSelection)
        .onChange(of: store.customersUsingAnnualReceipts) { _ in ensureCustomerSelection() }
        .onChange(of: customerName) { _ in
            amountText = ""
            note = ""
            statusMessage = ""
            errorMessage = ""
        }
        .alert(item: $revokeTarget) { receipt in
            Alert(
                title: Text("撤销整笔客户回款？"),
                message: Text("回款单 \(receipt.receiptNo)，金额 \(MoneyText.yuan(receipt.amountMilliYuan))。撤销记录会永久保留，不能修改或删除。"),
                primaryButton: .destructive(Text("确认撤销")) { revoke(receipt) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var entryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                Text("登记一笔回款")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.text)

                HStack(spacing: 18) {
                    formField(title: "客户") {
                        Menu {
                            ForEach(annualCustomers) { customer in
                                Button(customer.name) { customerName = customer.name }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "building.2")
                                    .foregroundColor(AppTheme.accentDark)
                                Text(customerName.isEmpty ? "请选择按年客户" : customerName)
                                    .foregroundColor(AppTheme.text)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(AppTheme.textMuted)
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppTheme.line, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                    }

                    formField(title: "回款日期") {
                        DatePicker("", selection: $receiptDate, displayedComponents: .date)
                            .labelsHidden()
                            .datePickerStyle(CompactDatePickerStyle())
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                            .padding(.horizontal, 8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppTheme.line, lineWidth: 1)
                            )
                    }
                }

                HStack(alignment: .top, spacing: 18) {
                    formField(title: "回款金额（元）") {
                        HStack(spacing: 8) {
                            Text("¥")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(AppTheme.textMuted)
                            TextField("例如 1200.000", text: $amountText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 15))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.line, lineWidth: 1)
                        )
                    }

                    formField(title: "备注") {
                        TextField("可选，最多 200 个字符", text: $note)
                            .font(.system(size: 15))
                            .padding(.horizontal, 12)
                            .frame(height: 46)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(AppTheme.line, lineWidth: 1)
                            )
                    }
                }

                Text("实际回款允许少于当前未收金额，但不能超过未收金额，因此不会产生客户预存款。")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textFaint)

                HStack {
                    Spacer()
                    Button("登记回款") { createReceipt() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(customerName.isEmpty)
                }
            }
            .padding(22)
        }
    }

    private var balancePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text("当前结算概览")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.text)
                summaryLine("累计未收加工费", MoneyText.yuan(outstanding), emphasized: true)
                summaryLine("本页有效回款合计", MoneyText.yuan(annualReceived), emphasized: false)
                summaryLine("回款记录", "\(receipts.count) 笔", emphasized: false)
                Divider().overlay(AppTheme.line)
                Text("客户结算方式：按年回款")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(red: 0.18, green: 0.44, blue: 0.68))
                Text("回款不冲销“按批结清”客户，也不能与清账管理同时使用。")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textFaint)
                    .lineSpacing(3)
            }
            .padding(22)
        }
        .frame(minHeight: 260)
    }

    private var emptyAnnualCustomerPanel: some View {
        Panel {
            VStack(spacing: 12) {
                Image(systemName: "building.2.crop.circle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(AppTheme.textFaint)
                Text("暂无按年回款客户")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Text("请先到“客户管理”把需要按年结算的客户设为“按年回款”，再回到这里登记到账。")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(24)
        }
    }

    private var receiptHistory: some View {
        Panel {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("回款记录")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text("有效记录和已撤销记录均永久保留")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    Spacer()
                    Text("\(receipts.count) 笔")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.textMuted)
                }
                .padding(.horizontal, 20)
                .frame(height: 62)
                .background(AppTheme.surfaceSoft)

                HStack(spacing: 12) {
                    Text("回款单号").frame(width: 170, alignment: .leading)
                    Text("回款日期").frame(width: 100, alignment: .leading)
                    Text("金额").frame(width: 120, alignment: .trailing)
                    Text("备注").frame(maxWidth: .infinity, alignment: .leading)
                    Text("状态").frame(width: 82, alignment: .center)
                    Text("操作").frame(width: 88, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

                if receipts.isEmpty {
                    EmptyStateView(title: "暂无回款记录", message: customerName.isEmpty ? "请先选择客户。" : "该客户还没有登记过回款。")
                        .frame(minHeight: 210)
                } else {
                    ForEach(Array(receipts.enumerated()), id: \.element.id) { index, receipt in
                        receiptRow(receipt, alternate: !index.isMultiple(of: 2))
                        if index < receipts.count - 1 {
                            Rectangle().fill(AppTheme.line).frame(height: 1).padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func receiptRow(_ receipt: CustomerReceipt, alternate: Bool) -> some View {
        HStack(spacing: 12) {
            Text(receipt.receiptNo)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.text)
                .frame(width: 170, alignment: .leading)
            Text(DateKey.string(from: receipt.receiptDate))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 100, alignment: .leading)
            Text(MoneyText.yuan(receipt.amountMilliYuan))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.text)
                .frame(width: 120, alignment: .trailing)
            Text(receipt.note.isEmpty ? "—" : receipt.note)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatusTag(
                text: receipt.isRevoked ? "已撤销" : "有效",
                foreground: receipt.isRevoked ? AppTheme.danger : AppTheme.success,
                background: receipt.isRevoked ? AppTheme.dangerSoft : Color(red: 0.93, green: 0.97, blue: 0.95)
            )
            .frame(width: 82, alignment: .center)

            Group {
                if receipt.isRevoked {
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textFaint)
                } else {
                    Button("撤销") { revokeTarget = receipt }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.danger)
                        .frame(width: 64, height: 34)
                        .background(AppTheme.dangerSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                        .buttonStyle(PlainButtonStyle())
                }
            }
            .frame(width: 88, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 54)
        .background(alternate ? AppTheme.surfaceSoft.opacity(0.68) : Color.white)
    }

    private func formField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryLine(_ label: String, _ value: String, emphasized: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: emphasized ? 19 : 13, weight: .bold, design: .monospaced))
                .foregroundColor(emphasized ? AppTheme.accentDark : AppTheme.text)
        }
    }

    private func statusBanner(_ message: String, success: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(message)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .foregroundColor(success ? AppTheme.success : AppTheme.danger)
        .padding(13)
        .background(success ? Color(red: 0.93, green: 0.97, blue: 0.95) : AppTheme.dangerSoft)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func ensureCustomerSelection() {
        guard !annualCustomers.isEmpty else {
            customerName = ""
            return
        }
        if !annualCustomers.contains(where: { $0.name == customerName }) {
            customerName = annualCustomers[0].name
        }
    }

    private func createReceipt() {
        errorMessage = ""
        statusMessage = ""
        guard !customerName.isEmpty else {
            errorMessage = "请先选择按年回款客户。"
            return
        }
        guard let amount = MoneyText.parseMilliYuan(amountText), amount > 0 else {
            errorMessage = "请输入大于 0、最多三位小数的回款金额。"
            return
        }
        guard amount <= outstanding else {
            errorMessage = "回款金额不能超过当前未收加工费 \(MoneyText.yuan(outstanding))。"
            return
        }
        do {
            let receipt = try store.createCustomerReceipt(
                customer: customerName,
                receiptDate: receiptDate,
                amountMilliYuan: amount,
                note: note
            )
            amountText = ""
            note = ""
            statusMessage = "回款登记成功：\(receipt.receiptNo)，\(MoneyText.yuan(receipt.amountMilliYuan))。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ receipt: CustomerReceipt) {
        do {
            try store.revokeCustomerReceipt(receipt)
            statusMessage = "已撤销回款 \(receipt.receiptNo)，原记录和撤销时间已保留。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
