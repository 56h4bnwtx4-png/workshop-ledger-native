import SwiftUI

struct EmployeePaymentManagementView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var employeeName = ""
    @State private var amountText = ""
    @State private var paymentDate = DateKey.startOfDay(Date())
    @State private var note = ""
    @State private var errorMessage = ""
    @State private var statusMessage = ""
    @State private var revokeTarget: EmployeePayment?

    private var payments: [EmployeePayment] {
        store.employeePayments
            .filter { $0.employee.caseInsensitiveCompare(employeeName) == .orderedSame }
            .sorted {
                if $0.paymentDate == $1.paymentDate { return $0.id > $1.id }
                return $0.paymentDate > $1.paymentDate
            }
    }

    private var balance: Int64 {
        guard !employeeName.isEmpty else { return 0 }
        return store.employeeBalanceMilliYuan(employee: employeeName)
    }

    private var effectivePaid: Int64 {
        payments.filter { !$0.isRevoked }.reduce(0) { $0 + $1.amountMilliYuan }
    }

    private var currentYearPaid: Int64 {
        let year = Calendar.current.component(.year, from: Date())
        return payments.reduce(0) { partial, payment in
            guard !payment.isRevoked,
                  Calendar.current.component(.year, from: payment.paymentDate) == year else { return partial }
            return partial + payment.amountMilliYuan
        }
    }

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "工资发放",
                brandSubtitle: "Payroll",
                brandIcon: "person.crop.circle.badge.checkmark",
                backAction: onClose
            ) {
                LocalModeBadge(text: "允许预支与多发")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeading(
                        eyebrow: "员工实发工资",
                        title: "工资发放",
                        note: "工资发放只登记员工、金额、日期和备注，不绑定具体流水。支持预支或多发，撤销时整笔保留历史。"
                    ) {
                        PageScopeBadge(label: "当前员工", value: employeeName.isEmpty ? "请选择" : employeeName)
                    }

                    if store.employees.isEmpty {
                        emptyEmployeePanel
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

                    paymentHistory
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 34)
            }
        }
        .onAppear(perform: ensureEmployeeSelection)
        .onChange(of: store.employees) { _ in ensureEmployeeSelection() }
        .onChange(of: employeeName) { _ in
            amountText = ""
            note = ""
            statusMessage = ""
            errorMessage = ""
        }
        .alert(item: $revokeTarget) { payment in
            Alert(
                title: Text("撤销整笔工资发放？"),
                message: Text("工资单 \(payment.paymentNo)，金额 \(MoneyText.yuan(payment.amountMilliYuan))。撤销记录会永久保留，不能修改或删除。"),
                primaryButton: .destructive(Text("确认撤销")) { revoke(payment) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var entryPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                Text("登记一笔工资发放")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.text)

                HStack(spacing: 18) {
                    formField(title: "员工") {
                        Menu {
                            ForEach(store.employees) { employee in
                                Button(employee.name) { employeeName = employee.name }
                            }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "person.fill")
                                    .foregroundColor(AppTheme.success)
                                Text(employeeName.isEmpty ? "请选择员工" : employeeName)
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

                    formField(title: "发放日期") {
                        DatePicker("", selection: $paymentDate, displayedComponents: .date)
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
                    formField(title: "发放金额（元）") {
                        HStack(spacing: 8) {
                            Text("¥")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(AppTheme.textMuted)
                            TextField("例如 800.000", text: $amountText)
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

                Text("发放金额可以超过当前应发工资，超过部分会形成预支或多发，并在年度统计中显示负数余额。")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textFaint)

                HStack {
                    Spacer()
                    Button("登记发放") { createPayment() }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(employeeName.isEmpty)
                }
            }
            .padding(22)
        }
    }

    private var balancePanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text("当前工资概览")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Text(balanceLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(balance >= 0 ? AppTheme.accentDark : AppTheme.success)
                Text(MoneyText.yuan(balance))
                    .font(.system(size: 23, weight: .bold, design: .monospaced))
                    .foregroundColor(balance >= 0 ? AppTheme.text : AppTheme.success)
                summaryLine("本页有效发放合计", MoneyText.yuan(effectivePaid))
                summaryLine("本年有效发放", MoneyText.yuan(currentYearPaid))
                summaryLine("发放记录", "\(payments.count) 笔")
                Divider().overlay(AppTheme.line)
                Text("余额计算：累计应发工资 − 累计有效发放。正数为未发，零为已结清，负数为预支或多发。")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textFaint)
                    .lineSpacing(3)
            }
            .padding(22)
        }
        .frame(minHeight: 280)
    }

    private var balanceLabel: String {
        if balance > 0 { return "截至今天仍应发放" }
        if balance < 0 { return "截至今天预支 / 多发" }
        return "截至今天工资已发清"
    }

    private var emptyEmployeePanel: some View {
        Panel {
            VStack(spacing: 12) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(AppTheme.textFaint)
                Text("暂无员工档案")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Text("请先到“员工管理”新增员工并设置工资单价，再回到这里登记工资发放。")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textMuted)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .padding(24)
        }
    }

    private var paymentHistory: some View {
        Panel {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("工资发放记录")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text("有效记录和已撤销记录均永久保留")
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    Spacer()
                    Text("\(payments.count) 笔")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(AppTheme.textMuted)
                }
                .padding(.horizontal, 20)
                .frame(height: 62)
                .background(AppTheme.surfaceSoft)

                HStack(spacing: 12) {
                    Text("工资单号").frame(width: 170, alignment: .leading)
                    Text("发放日期").frame(width: 100, alignment: .leading)
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

                if payments.isEmpty {
                    EmptyStateView(title: "暂无工资发放记录", message: employeeName.isEmpty ? "请先选择员工。" : "该员工还没有登记过工资发放。")
                        .frame(minHeight: 210)
                } else {
                    ForEach(Array(payments.enumerated()), id: \.element.id) { index, payment in
                        paymentRow(payment, alternate: !index.isMultiple(of: 2))
                        if index < payments.count - 1 {
                            Rectangle().fill(AppTheme.line).frame(height: 1).padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func paymentRow(_ payment: EmployeePayment, alternate: Bool) -> some View {
        HStack(spacing: 12) {
            Text(payment.paymentNo)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.text)
                .frame(width: 170, alignment: .leading)
            Text(DateKey.string(from: payment.paymentDate))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 100, alignment: .leading)
            Text(MoneyText.yuan(payment.amountMilliYuan))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.text)
                .frame(width: 120, alignment: .trailing)
            Text(payment.note.isEmpty ? "—" : payment.note)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            StatusTag(
                text: payment.isRevoked ? "已撤销" : "有效",
                foreground: payment.isRevoked ? AppTheme.danger : AppTheme.success,
                background: payment.isRevoked ? AppTheme.dangerSoft : Color(red: 0.93, green: 0.97, blue: 0.95)
            )
            .frame(width: 82, alignment: .center)

            Group {
                if payment.isRevoked {
                    Text("—")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textFaint)
                } else {
                    Button("撤销") { revokeTarget = payment }
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

    private func summaryLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(AppTheme.textMuted)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundColor(AppTheme.text)
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

    private func ensureEmployeeSelection() {
        guard !store.employees.isEmpty else {
            employeeName = ""
            return
        }
        if !store.employees.contains(where: { $0.name == employeeName }) {
            employeeName = store.employees[0].name
        }
    }

    private func createPayment() {
        errorMessage = ""
        statusMessage = ""
        guard !employeeName.isEmpty else {
            errorMessage = "请先选择员工。"
            return
        }
        guard let amount = MoneyText.parseMilliYuan(amountText), amount > 0 else {
            errorMessage = "请输入大于 0、最多三位小数的发放金额。"
            return
        }
        do {
            let payment = try store.createEmployeePayment(
                employee: employeeName,
                paymentDate: paymentDate,
                amountMilliYuan: amount,
                note: note
            )
            amountText = ""
            note = ""
            statusMessage = "工资发放登记成功：\(payment.paymentNo)，\(MoneyText.yuan(payment.amountMilliYuan))。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ payment: EmployeePayment) {
        do {
            try store.revokeEmployeePayment(payment)
            statusMessage = "已撤销工资发放 \(payment.paymentNo)，原记录和撤销时间已保留。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
