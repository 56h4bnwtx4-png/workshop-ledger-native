import SwiftUI

struct DirectoryView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var destination: SettingsDestination?

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "设置管理",
                brandSubtitle: "Account Settings",
                brandIcon: "gearshape",
                backAction: onClose
            ) {
                LocalModeBadge(text: store.cloudBadgeText)
            }

            ScrollView {
                VStack(spacing: 18) {
                    PageHeading(
                        eyebrow: "基础档案与结算",
                        title: "设置管理",
                        note: "客户、员工、回款、清账、工资和云端备份均已拆分为独立页面。金额统一保留三位小数。"
                    ) {
                        PageScopeBadge(label: "当前软件", value: "段誉的段")
                    }

                    settingsRow(
                        title: "客户管理",
                        note: "维护客户档案、结算方式与当前加工单价；同一客户所有型号共用单价。",
                        icon: "building.2",
                        color: AppTheme.accentDark,
                        badge: "\(store.customers.count) 位客户"
                    ) { destination = .customers }

                    settingsRow(
                        title: "员工管理",
                        note: "维护员工档案与统一工资单价；未设置工资单价的员工不能提交计件流水。",
                        icon: "person.2",
                        color: AppTheme.success,
                        badge: "\(store.employees.count) 位员工"
                    ) { destination = .employees }

                    settingsRow(
                        title: "客户回款",
                        note: "仅用于“按年回款”客户，登记不绑定具体流水的整笔到账记录。",
                        icon: "banknote",
                        color: Color(red: 0.18, green: 0.44, blue: 0.68),
                        badge: "\(store.customersUsingAnnualReceipts.count) 位按年客户"
                    ) { destination = .receipts }

                    settingsRow(
                        title: "清账管理",
                        note: "仅用于“按批结清”客户，按所选流水整批结清并锁定；只能整批撤销。",
                        icon: "checkmark.seal",
                        color: AppTheme.accentDark,
                        badge: "\(store.customersUsingBatchSettlement.count) 位按批客户"
                    ) { destination = .settlement }

                    settingsRow(
                        title: "工资发放",
                        note: "按员工登记实发工资，支持预支或多发；只能整笔撤销且保留撤销记录。",
                        icon: "person.crop.circle.badge.checkmark",
                        color: Color(red: 0.38, green: 0.34, blue: 0.64),
                        badge: "\(store.employeePayments.count) 笔记录"
                    ) { destination = .payments }

                    settingsRow(
                        title: "云端备份与恢复",
                        note: store.cloudStatusText,
                        icon: store.isCloudLoggedIn ? "icloud.fill" : "icloud.slash",
                        color: store.isCloudLoggedIn ? AppTheme.success : AppTheme.textFaint,
                        badge: "账号与快照"
                    ) { destination = .cloud }
                }
                .padding(.horizontal, 38)
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
        }
        .fullScreenCover(item: $destination) { item in
            switch item {
            case .customers:
                CustomerDirectoryView { destination = nil }
            case .employees:
                EmployeeDirectoryView { destination = nil }
            case .receipts:
                CustomerReceiptManagementView { destination = nil }
            case .settlement:
                SettlementView { destination = nil }
            case .payments:
                EmployeePaymentManagementView { destination = nil }
            case .cloud:
                CloudBackupView { destination = nil }
            }
        }
    }

    private func settingsRow(
        title: String,
        note: String,
        icon: String,
        color: Color,
        badge: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Panel {
                HStack(spacing: 18) {
                    Image(systemName: icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundColor(color)
                        .frame(width: 52, height: 52)
                        .background(color.opacity(0.11))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 16)

                    Text(badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(color)
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                        .background(color.opacity(0.09))
                        .clipShape(Capsule())

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(AppTheme.textFaint)
                }
                .padding(20)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private enum SettingsDestination: String, Identifiable {
    case customers
    case employees
    case receipts
    case settlement
    case payments
    case cloud

    var id: String { rawValue }
}

struct CustomerDirectoryView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var editorTarget: CustomerEditorTarget?
    @State private var detailTarget: Customer?
    @State private var deleteTarget: Customer?

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "客户管理",
                brandSubtitle: "Customers",
                brandIcon: "building.2",
                backAction: onClose
            ) {
                LocalModeBadge(text: "加工单价三位小数")
            }

            ScrollView {
                VStack(spacing: 18) {
                    PageHeading(
                        eyebrow: "客户档案",
                        title: "客户管理",
                        note: "同一客户的所有型号共用当前加工单价。首次设置单价时，会覆盖该客户此前尚未保存单价的历史流水。"
                    ) {
                        Button {
                            editorTarget = CustomerEditorTarget(customer: nil)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "plus")
                                Text("新增客户")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }

                    customerTable
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 34)
            }
        }
        .sheet(item: $editorTarget) { target in
            CustomerEditorSheet(
                customer: target.customer,
                settlementLocked: target.customer.map(hasActiveSettlement) ?? false
            ) { name, price, mode in
                try save(customer: target.customer, name: name, price: price, mode: mode)
            }
        }
        .sheet(item: $detailTarget) { customer in
            CustomerDetailSheet(customer: customer)
        }
        .alert(item: $deleteTarget) { customer in
            Alert(
                title: Text("确认删除客户？"),
                message: Text("将删除“\(customer.name)”档案。已有流水中的客户名称不会改变。"),
                primaryButton: .destructive(Text("删除客户")) { delete(customer) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var customerTable: some View {
        Panel {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("客户名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("结算方式").frame(width: 120, alignment: .leading)
                    Text("当前加工单价").frame(width: 150, alignment: .trailing)
                    Text("最近修改").frame(width: 150, alignment: .leading)
                    Text("操作").frame(width: 132, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(AppTheme.surfaceSoft)
                .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

                if store.customers.isEmpty {
                    EmptyStateView(title: "暂无客户档案", message: "点击右上角“新增客户”建立第一位客户。")
                        .frame(minHeight: 280)
                } else {
                    ForEach(Array(store.customers.enumerated()), id: \.element.id) { index, customer in
                        customerRow(customer, alternate: !index.isMultiple(of: 2))
                        if index < store.customers.count - 1 {
                            Rectangle().fill(AppTheme.line).frame(height: 1).padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func customerRow(_ customer: Customer, alternate: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "building.2")
                    .foregroundColor(AppTheme.accentDark)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(customer.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(AppTheme.text)
                    Text(hasActiveSettlement(customer) ? "已有结款记录 · 结算方式已锁定" : "结算方式可调整")
                        .font(.system(size: 10))
                        .foregroundColor(hasActiveSettlement(customer) ? AppTheme.accentDark : AppTheme.textFaint)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            StatusTag(
                text: customer.settlementMode.title,
                foreground: customer.settlementMode == .batch ? AppTheme.accentDark : Color(red: 0.18, green: 0.44, blue: 0.68),
                background: customer.settlementMode == .batch ? AppTheme.accentSoft : Color(red: 0.93, green: 0.96, blue: 1)
            )
            .frame(width: 120, alignment: .leading)

            Text(MoneyText.yuan(customer.unitPriceMilliYuan))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(customer.unitPriceMilliYuan == nil ? AppTheme.danger : AppTheme.text)
                .frame(width: 150, alignment: .trailing)

            Text(formatDirectoryTime(customer.updatedAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 7) {
                directoryActionButton(icon: "eye", color: AppTheme.textMuted) {
                    detailTarget = customer
                }
                directoryActionButton(icon: "pencil", color: AppTheme.accentDark) {
                    editorTarget = CustomerEditorTarget(customer: customer)
                }
                directoryActionButton(icon: "trash", color: AppTheme.danger) {
                    deleteTarget = customer
                }
            }
            .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 62)
        .background(alternate ? AppTheme.surfaceSoft.opacity(0.7) : Color.white)
    }

    private func hasActiveSettlement(_ customer: Customer) -> Bool {
        store.settlementBatches.contains {
            !$0.isRevoked && $0.customer.caseInsensitiveCompare(customer.name) == .orderedSame
        } || store.customerReceipts.contains {
            !$0.isRevoked && $0.customer.caseInsensitiveCompare(customer.name) == .orderedSame
        }
    }

    private func save(
        customer: Customer?,
        name: String,
        price: Int64?,
        mode: CustomerSettlementMode
    ) throws {
        if let customer {
            try store.updateCustomer(customer, name: name, unitPriceMilliYuan: price, settlementMode: mode)
        } else {
            try store.addCustomer(name: name, unitPriceMilliYuan: price, settlementMode: mode)
        }
    }

    private func delete(_ customer: Customer) {
        do {
            try store.deleteCustomer(customer)
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private struct CustomerEditorTarget: Identifiable {
    let customer: Customer?
    var id: String { customer.map { String($0.id) } ?? "new" }
}

private struct CustomerEditorSheet: View {
    let customer: Customer?
    let settlementLocked: Bool
    let onSave: (String, Int64?, CustomerSettlementMode) throws -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var name: String
    @State private var priceText: String
    @State private var settlementMode: CustomerSettlementMode
    @State private var errorMessage = ""
    @State private var showingPriceConfirmation = false
    @State private var pendingPrice: Int64?

    init(
        customer: Customer?,
        settlementLocked: Bool,
        onSave: @escaping (String, Int64?, CustomerSettlementMode) throws -> Void
    ) {
        self.customer = customer
        self.settlementLocked = settlementLocked
        self.onSave = onSave
        _name = State(initialValue: customer?.name ?? "")
        _priceText = State(initialValue: MoneyText.plainYuan(customer?.unitPriceMilliYuan))
        _settlementMode = State(initialValue: customer?.settlementMode ?? .batch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "building.2")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.accentDark)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(customer == nil ? "新增客户" : "编辑客户")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("同一客户所有型号共用同一加工单价")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }

            fieldLabel("客户名称")
            TextField("请输入客户名称", text: $name)
                .modifier(EditorFieldStyle())
                .onChange(of: name) { _ in errorMessage = "" }

            fieldLabel("加工单价（元 / 件·色）")
            HStack(spacing: 8) {
                Text("¥")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textMuted)
                TextField("例如 0.350", text: $priceText)
                    .keyboardType(.decimalPad)
                    .onChange(of: priceText) { _ in errorMessage = "" }
            }
            .modifier(EditorFieldStyle())
            Text("最多三位小数。应收加工费 = 单价 × 数量 × 色数。")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textFaint)

            fieldLabel("结算方式")
            Picker("结算方式", selection: $settlementMode) {
                ForEach(CustomerSettlementMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .disabled(settlementLocked)
            .opacity(settlementLocked ? 0.58 : 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(settlementMode.shortDescription)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
                if settlementLocked {
                    Text("该客户已有有效结款或回款记录，结算方式已锁定。请到对应管理页撤销全部记录后再修改。")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppTheme.danger)
                } else {
                    Text("客户产生首笔有效结款或回款后，结算方式将自动锁定。")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textFaint)
                }
            }

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.danger)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") { presentationMode.wrappedValue.dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("保存") { attemptSave() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(26)
        .frame(minWidth: 620, minHeight: 500)
        .background(AppTheme.background)
        .alert(isPresented: $showingPriceConfirmation) {
            Alert(
                title: Text("首次设置加工单价"),
                message: Text("保存后，该客户所有尚未保存单价的历史流水都会使用本次单价。以后修改单价只影响新录入流水。是否继续？"),
                primaryButton: .default(Text("确认并覆盖历史")) { performSave(price: pendingPrice) },
                secondaryButton: .cancel(Text("返回检查"))
            )
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(AppTheme.textMuted)
    }

    private func attemptSave() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "客户名称不能为空。"
            return
        }
        guard trimmedName.count <= 40 else {
            errorMessage = "客户名称最多 40 个字符。"
            return
        }

        let trimmedPrice = priceText.trimmingCharacters(in: .whitespacesAndNewlines)
        var price: Int64?
        if trimmedPrice.isEmpty {
            if customer?.unitPriceMilliYuan != nil {
                errorMessage = "已设置的加工单价不能清空；后续修改只影响新录入流水。"
                return
            }
        } else {
            guard let parsed = MoneyText.parseMilliYuan(trimmedPrice), parsed > 0 else {
                errorMessage = "加工单价必须是大于 0、最多三位小数的金额。"
                return
            }
            price = parsed
        }

        if customer != nil, customer?.unitPriceMilliYuan == nil, price != nil {
            pendingPrice = price
            showingPriceConfirmation = true
        } else {
            performSave(price: price)
        }
    }

    private func performSave(price: Int64?) {
        do {
            try onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), price, settlementMode)
            presentationMode.wrappedValue.dismiss()
        } catch {
            let message = error.localizedDescription
            errorMessage = message.lowercased().contains("unique") ? "该客户名称已存在。" : message
        }
    }
}

private struct EmployeeDirectoryView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var editorTarget: EmployeeEditorTarget?
    @State private var detailTarget: Employee?
    @State private var deleteTarget: Employee?

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "员工管理",
                brandSubtitle: "Employees",
                brandIcon: "person.2",
                backAction: onClose
            ) {
                LocalModeBadge(text: "工资单价三位小数")
            }

            ScrollView {
                VStack(spacing: 18) {
                    PageHeading(
                        eyebrow: "员工档案",
                        title: "员工管理",
                        note: "每位员工使用统一工资单价。首次设置时，会覆盖该员工此前尚未保存工资单价的历史流水。"
                    ) {
                        Button {
                            editorTarget = EmployeeEditorTarget(employee: nil)
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "plus")
                                Text("新增员工")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    }

                    employeeTable
                }
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 34)
            }
        }
        .sheet(item: $editorTarget) { target in
            EmployeeEditorSheet(employee: target.employee) { name, wage in
                if let employee = target.employee {
                    try store.updateEmployee(employee, name: name, wageMilliYuan: wage)
                } else {
                    try store.addEmployee(name: name, wageMilliYuan: wage)
                }
            }
        }
        .sheet(item: $detailTarget) { employee in
            EmployeeDetailSheet(employee: employee)
        }
        .alert(item: $deleteTarget) { employee in
            Alert(
                title: Text("确认删除员工？"),
                message: Text("将删除“\(employee.name)”档案。已有流水中的员工名称不会改变。"),
                primaryButton: .destructive(Text("删除员工")) { delete(employee) },
                secondaryButton: .cancel(Text("取消"))
            )
        }
    }

    private var employeeTable: some View {
        Panel {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Text("员工名称").frame(maxWidth: .infinity, alignment: .leading)
                    Text("当前工资单价").frame(width: 170, alignment: .trailing)
                    Text("最近修改").frame(width: 170, alignment: .leading)
                    Text("操作").frame(width: 132, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
                .padding(.horizontal, 20)
                .frame(height: 44)
                .background(AppTheme.surfaceSoft)
                .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

                if store.employees.isEmpty {
                    EmptyStateView(title: "暂无员工档案", message: "点击右上角“新增员工”建立第一位员工。")
                        .frame(minHeight: 280)
                } else {
                    ForEach(Array(store.employees.enumerated()), id: \.element.id) { index, employee in
                        employeeRow(employee, alternate: !index.isMultiple(of: 2))
                        if index < store.employees.count - 1 {
                            Rectangle().fill(AppTheme.line).frame(height: 1).padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func employeeRow(_ employee: Employee, alternate: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "person.fill")
                    .foregroundColor(AppTheme.success)
                    .frame(width: 34, height: 34)
                    .background(Color(red: 0.93, green: 0.97, blue: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(employee.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.text)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(MoneyText.yuan(employee.wageMilliYuan))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(employee.wageMilliYuan == nil ? AppTheme.danger : AppTheme.text)
                .frame(width: 170, alignment: .trailing)

            Text(formatDirectoryTime(employee.updatedAt))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 170, alignment: .leading)

            HStack(spacing: 7) {
                directoryActionButton(icon: "eye", color: AppTheme.textMuted) {
                    detailTarget = employee
                }
                directoryActionButton(icon: "pencil", color: AppTheme.accentDark) {
                    editorTarget = EmployeeEditorTarget(employee: employee)
                }
                directoryActionButton(icon: "trash", color: AppTheme.danger) {
                    deleteTarget = employee
                }
            }
            .frame(width: 132, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 62)
        .background(alternate ? AppTheme.surfaceSoft.opacity(0.7) : Color.white)
    }

    private func delete(_ employee: Employee) {
        do {
            try store.deleteEmployee(employee)
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private struct EmployeeEditorTarget: Identifiable {
    let employee: Employee?
    var id: String { employee.map { String($0.id) } ?? "new" }
}

private struct EmployeeEditorSheet: View {
    let employee: Employee?
    let onSave: (String, Int64?) throws -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var name: String
    @State private var wageText: String
    @State private var errorMessage = ""
    @State private var showingWageConfirmation = false
    @State private var pendingWage: Int64?

    init(employee: Employee?, onSave: @escaping (String, Int64?) throws -> Void) {
        self.employee = employee
        self.onSave = onSave
        _name = State(initialValue: employee?.name ?? "")
        _wageText = State(initialValue: MoneyText.plainYuan(employee?.wageMilliYuan))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "person.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.success)
                    .frame(width: 46, height: 46)
                    .background(Color(red: 0.93, green: 0.97, blue: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(employee == nil ? "新增员工" : "编辑员工")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("每位员工使用统一工资单价")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }

            Text("员工名称")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
            TextField("请输入员工名称", text: $name)
                .modifier(EditorFieldStyle())
                .onChange(of: name) { _ in errorMessage = "" }

            Text("工资单价（元 / 件·色）")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
            HStack(spacing: 8) {
                Text("¥")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(AppTheme.textMuted)
                TextField("例如 0.250", text: $wageText)
                    .keyboardType(.decimalPad)
                    .onChange(of: wageText) { _ in errorMessage = "" }
            }
            .modifier(EditorFieldStyle())
            Text("应发工资 = 工资单价 × 数量 × 色数。未设置工资单价时，禁止提交该员工的计件流水。")
                .font(.system(size: 11))
                .foregroundColor(AppTheme.textFaint)

            if !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.danger)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") { presentationMode.wrappedValue.dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("保存") { attemptSave() }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(26)
        .frame(minWidth: 600, minHeight: 430)
        .background(AppTheme.background)
        .alert(isPresented: $showingWageConfirmation) {
            Alert(
                title: Text("首次设置员工工资单价"),
                message: Text("保存后，该员工所有尚未保存工资单价的历史流水都会使用本次单价。以后修改工资单价只影响新录入流水。是否继续？"),
                primaryButton: .default(Text("确认并覆盖历史")) { performSave(wage: pendingWage) },
                secondaryButton: .cancel(Text("返回检查"))
            )
        }
    }

    private func attemptSave() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "员工名称不能为空。"
            return
        }
        guard trimmedName.count <= 40 else {
            errorMessage = "员工名称最多 40 个字符。"
            return
        }

        let trimmedWage = wageText.trimmingCharacters(in: .whitespacesAndNewlines)
        var wage: Int64?
        if trimmedWage.isEmpty {
            if employee?.wageMilliYuan != nil {
                errorMessage = "已设置的工资单价不能清空；后续修改只影响新录入流水。"
                return
            }
        } else {
            guard let parsed = MoneyText.parseMilliYuan(trimmedWage), parsed > 0 else {
                errorMessage = "工资单价必须是大于 0、最多三位小数的金额。"
                return
            }
            wage = parsed
        }

        if employee != nil, employee?.wageMilliYuan == nil, wage != nil {
            pendingWage = wage
            showingWageConfirmation = true
        } else {
            performSave(wage: wage)
        }
    }

    private func performSave(wage: Int64?) {
        do {
            try onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), wage)
            presentationMode.wrappedValue.dismiss()
        } catch {
            let message = error.localizedDescription
            errorMessage = message.lowercased().contains("unique") ? "该员工名称已存在。" : message
        }
    }
}

private struct CustomerDetailSheet: View {
    let customer: Customer
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("客户档案")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(AppTheme.text)
            detailRow("名称", customer.name)
            detailRow("结算方式", customer.settlementMode.title)
            detailRow("加工单价", MoneyText.yuan(customer.unitPriceMilliYuan))
            detailRow("档案编号", String(customer.id))
            detailRow("创建时间", formatDirectoryTime(customer.createdAt, seconds: true))
            detailRow("最近修改", formatDirectoryTime(customer.updatedAt, seconds: true))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("关闭") { presentationMode.wrappedValue.dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(26)
        .frame(minWidth: 460, minHeight: 400)
        .background(AppTheme.background)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.textFaint)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.text)
            Spacer()
        }
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)
    }
}

private struct EmployeeDetailSheet: View {
    let employee: Employee
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("员工档案")
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(AppTheme.text)
            detailRow("名称", employee.name)
            detailRow("工资单价", MoneyText.yuan(employee.wageMilliYuan))
            detailRow("档案编号", String(employee.id))
            detailRow("创建时间", formatDirectoryTime(employee.createdAt, seconds: true))
            detailRow("最近修改", formatDirectoryTime(employee.updatedAt, seconds: true))
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("关闭") { presentationMode.wrappedValue.dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(26)
        .frame(minWidth: 460, minHeight: 360)
        .background(AppTheme.background)
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.textFaint)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.text)
            Spacer()
        }
        .padding(.vertical, 10)
        .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)
    }
}

private struct EditorFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 15))
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

private func directoryActionButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(color)
            .frame(width: 36, height: 36)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            )
            .contentShape(Rectangle())
    }
    .buttonStyle(PlainButtonStyle())
}

private func formatDirectoryTime(_ date: Date, seconds: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = seconds ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}
