import SwiftUI

struct QueryView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var mode: ReportMode = .ledger
    @State private var selectedYear = Calendar.current.component(.year, from: Date())
    @State private var ledgerStart = QueryView.yearStart(Calendar.current.component(.year, from: Date()))
    @State private var ledgerEnd = QueryView.yearEnd(Calendar.current.component(.year, from: Date()))
    @State private var employeeName = ""
    @State private var selectedEmployeePeriod: ReportPeriod = .year
    @State private var employeeReferenceDate = Date()
    @State private var customerName = ""
    @State private var selectedCustomerPeriod: ReportPeriod = .year
    @State private var customerReferenceDate = Date()
    @State private var colorFilter: Int?
    @State private var tableWidth: CGFloat = 900
    @State private var shareItems: [Any] = []
    @State private var showShareSheet = false
    @State private var errorMessage: String?

    private var records: [QueryRecord] {
        switch mode {
        case .ledger:
            guard ledgerStart <= ledgerEnd else { return [] }
            return store.queryRecords(
                startDate: ledgerStart,
                endDate: ledgerEnd,
                employee: "",
                customer: "",
                colorCount: nil,
                modelText: ""
            )
        case .employee:
            guard !employeeName.isEmpty else { return [] }
            let bounds = periodBounds(reference: employeeReferenceDate, period: selectedEmployeePeriod)
            return store.queryRecords(
                startDate: bounds.start,
                endDate: bounds.inclusiveEnd,
                employee: employeeName,
                customer: "",
                colorCount: nil,
                modelText: ""
            )
        case .customer:
            guard !customerName.isEmpty else { return [] }
            let bounds = periodBounds(reference: customerReferenceDate, period: selectedCustomerPeriod)
            return store.queryRecords(
                startDate: bounds.start,
                endDate: bounds.inclusiveEnd,
                employee: "",
                customer: customerName,
                colorCount: colorFilter,
                modelText: ""
            )
        }
    }

    private var customerPeriodRecords: [QueryRecord] {
        guard let bounds = customerBounds else { return [] }
        return store.queryRecords(
            startDate: bounds.start,
            endDate: bounds.inclusiveEnd,
            employee: "",
            customer: customerName,
            colorCount: nil,
            modelText: ""
        )
    }

    private var customerBounds: (start: Date, inclusiveEnd: Date)? {
        guard !customerName.isEmpty else { return nil }
        return periodBounds(reference: customerReferenceDate, period: selectedCustomerPeriod)
    }

    private var availableYears: [Int] {
        let calendar = Calendar.current
        var years = Set<Int>([Calendar.current.component(.year, from: Date()), selectedYear])
        for bill in store.bills {
            years.insert(calendar.component(.year, from: bill.date))
        }
        for batch in store.settlementBatches {
            years.insert(calendar.component(.year, from: batch.settlementDate))
        }
        for receipt in store.customerReceipts {
            years.insert(calendar.component(.year, from: receipt.receiptDate))
        }
        for payment in store.employeePayments {
            years.insert(calendar.component(.year, from: payment.paymentDate))
        }
        return years.sorted(by: >)
    }

    private var factorySettlement: FactoryAnnualSettlement {
        store.factoryAnnualSettlement(year: selectedYear)
    }

    private var customerSettlement: CustomerAnnualSettlement? {
        guard !customerName.isEmpty else { return nil }
        return store.customerAnnualSettlement(customer: customerName, year: selectedYear)
    }

    private var employeeSettlement: EmployeeAnnualSettlement? {
        guard !employeeName.isEmpty else { return nil }
        return store.employeeAnnualSettlement(employee: employeeName, year: selectedYear)
    }

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "报表与导出",
                brandSubtitle: "Local Reports",
                brandIcon: "chart.bar.xaxis",
                backAction: onClose
            ) {
                LocalModeBadge(text: "CSV 本机导出")
            }

            ScrollView {
                VStack(spacing: 0) {
                    PageHeading(
                        eyebrow: "计件数据分析",
                        title: "报表与导出",
                        note: "年度结算读取本机正式账单、结款、客户回款与工资发放；金额固定三位小数，不包含未提交草稿。"
                    ) {
                        PageScopeBadge(label: "当前报表", value: mode.scopeTitle)
                    }
                    reportCard
                }
                .padding(.horizontal, 38)
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
        }
        .onAppear {
            ensureSelections()
            ensureYearSelection()
        }
        .onChange(of: store.allEmployeeNames) { _ in ensureEmployeeSelection() }
        .onChange(of: store.allCustomerNames) { _ in ensureCustomerSelection() }
        .onChange(of: availableYears) { _ in ensureYearSelection() }
        .onChange(of: mode) { _ in ensureSelections() }
        .onChange(of: selectedYear) { _ in applyYearToFilters() }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .alert(isPresented: errorBinding) {
            Alert(
                title: Text("导出失败"),
                message: Text(errorMessage ?? "未知错误"),
                dismissButton: .default(Text("知道了")) { errorMessage = nil }
            )
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var reportCard: some View {
        VStack(spacing: 0) {
            reportTabs
            filters
            reportSummary
            reportTable
            HStack {
                Text("共 \(records.count) 条明细")
                Spacer()
                Text("明细金额按录入时保存的单价计算")
            }
            .font(.system(size: 12))
            .foregroundColor(AppTheme.textFaint)
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(AppTheme.surfaceSoft)
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .top)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        )
    }

    private var reportTabs: some View {
        HStack(spacing: 4) {
            ForEach(ReportMode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    Text(item.tabTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(mode == item ? AppTheme.accentDark : AppTheme.textMuted)
                        .padding(.horizontal, 20)
                        .frame(height: 46)
                        .background(mode == item ? Color.white : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .stroke(mode == item ? AppTheme.line : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(AppTheme.surfaceSoft)
        .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)
    }
    @ViewBuilder
    private var filters: some View {
        HStack(alignment: .bottom, spacing: 12) {
            yearPicker

            switch mode {
            case .ledger:
                dateFilterField(title: "明细开始日期", date: $ledgerStart)
                dateFilterField(title: "明细结束日期", date: $ledgerEnd)
                Button("回到本年度") {
                    ledgerStart = QueryView.yearStart(selectedYear)
                    ledgerEnd = QueryView.yearEnd(selectedYear)
                }
                .buttonStyle(SecondaryButtonStyle())
            case .employee:
                periodPicker(title: "明细周期", selection: $selectedEmployeePeriod)
                personPicker(title: "员工", selection: $employeeName, options: store.allEmployeeNames, placeholder: "暂无员工")
                dateFilterField(title: selectedEmployeePeriod.fieldLabel, date: $employeeReferenceDate)
            case .customer:
                periodPicker(title: "明细周期", selection: $selectedCustomerPeriod)
                personPicker(title: "客户", selection: $customerName, options: store.allCustomerNames, placeholder: "暂无客户")
                colorPicker
                dateFilterField(title: selectedCustomerPeriod.fieldLabel, date: $customerReferenceDate)
            }

            Spacer(minLength: 12)

            Button(action: exportCSV) {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.arrow.down")
                    Text("导出 CSV")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)
    }

    private var yearPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("年度结算")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
            Picker("", selection: $selectedYear) {
                ForEach(availableYears, id: \.self) { year in
                    Text("\(year) 年").tag(year)
                }
            }
            .labelsHidden()
            .pickerStyle(MenuPickerStyle())
            .frame(width: 108, height: 38)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            )
        }
    }

    private func dateFilterField(title: String, date: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
            DatePicker("", selection: date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(CompactDatePickerStyle())
                .environment(\.locale, Locale(identifier: "zh_CN"))
                .frame(width: 132, height: 38)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
                )
        }
    }

    private func periodPicker(title: String, selection: Binding<ReportPeriod>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
            Picker("", selection: selection) {
                ForEach(ReportPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            .labelsHidden()
            .pickerStyle(MenuPickerStyle())
            .frame(width: 120, height: 38)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
            )
        }
    }
    private func personPicker(title: String, selection: Binding<String>, options: [String], placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
            Picker("", selection: selection) {
                if options.isEmpty {
                    Text(placeholder).tag("")
                } else {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(MenuPickerStyle())
            .frame(width: 155, height: 38)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
            )
        }
    }

    private var colorPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("色数")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
            Picker("", selection: $colorFilter) {
                Text("全部色数").tag(Int?.none)
                ForEach(1...5, id: \.self) { color in
                    Text("\(color) 色").tag(Int?.some(color))
                }
            }
            .labelsHidden()
            .pickerStyle(MenuPickerStyle())
            .frame(width: 112, height: 38)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
            )
        }
    }
    private var reportSummary: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(resultTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text(resultDescription)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Text(resultCaption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppTheme.textMuted)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(AppTheme.surfaceSoft)
                    .clipShape(Capsule())
            }

            annualSettlementSection

            HStack(spacing: 12) {
                metricCard(label: "计酬工作量", value: "\(totalWorkload)", unit: "件", primary: true)
                metricCard(label: "明细记录", value: "\(records.count)", unit: "条", primary: false)
                metricCard(label: groupMetricLabel, value: "\(groupMetricValue)", unit: "位", primary: false)
            }

            if mode == .customer {
                colorBreakdown
            }
        }
        .padding(20)
        .background(AppTheme.surfaceSoft)
        .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)
    }

    private var annualSettlementSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock")
                    .foregroundColor(AppTheme.accentDark)
                Text("\(selectedYear) 年度结算")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Spacer()
                Text("本年发生额 + 截至年末累计余额")
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.textFaint)
            }

            switch mode {
            case .ledger:
                HStack(spacing: 8) {
                    amountMetricCard(
                        label: "年度应收加工费",
                        value: MoneyText.yuan(factorySettlement.receivableMilliYuan),
                        caption: "全部客户",
                        color: AppTheme.accentDark
                    )
                    amountMetricCard(
                        label: "年度客户实际收款",
                        value: MoneyText.yuan(factorySettlement.receivableCollectedMilliYuan),
                        caption: "按批 + 按年",
                        color: Color(red: 0.18, green: 0.44, blue: 0.68)
                    )
                    amountMetricCard(
                        label: "年度应付工资",
                        value: MoneyText.yuan(factorySettlement.payableMilliYuan),
                        caption: "全部员工",
                        color: Color(red: 0.38, green: 0.34, blue: 0.64)
                    )
                    amountMetricCard(
                        label: "年度工资实际支出",
                        value: MoneyText.yuan(factorySettlement.wagesPaidMilliYuan),
                        caption: "有效工资单",
                        color: AppTheme.success
                    )
                    amountMetricCard(
                        label: "年度账面差额",
                        value: MoneyText.yuan(factorySettlement.bookDifferenceMilliYuan),
                        caption: "应收 − 应付",
                        color: factorySettlement.bookDifferenceMilliYuan >= 0 ? AppTheme.text : AppTheme.danger
                    )
                }
            case .employee:
                if let settlement = employeeSettlement {
                    HStack(spacing: 8) {
                        amountMetricCard(
                            label: "年度应发工资",
                            value: MoneyText.yuan(settlement.annualPayableMilliYuan),
                            caption: employeeName,
                            color: Color(red: 0.38, green: 0.34, blue: 0.64)
                        )
                        amountMetricCard(
                            label: "年度实发工资",
                            value: MoneyText.yuan(settlement.annualPaidMilliYuan),
                            caption: "有效工资单",
                            color: AppTheme.success
                        )
                        amountMetricCard(
                            label: "年末余额",
                            value: MoneyText.yuan(settlement.balanceAtYearEndMilliYuan),
                            caption: employeeBalanceCaption(settlement.balanceAtYearEndMilliYuan),
                            color: settlement.balanceAtYearEndMilliYuan < 0 ? AppTheme.success : AppTheme.accentDark
                        )
                    }
                } else {
                    Text("请选择员工后查看年度结算。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            case .customer:
                if let settlement = customerSettlement {
                    HStack(spacing: 8) {
                        amountMetricCard(
                            label: "年度加工费应收",
                            value: MoneyText.yuan(settlement.annualReceivableMilliYuan),
                            caption: customerName,
                            color: AppTheme.accentDark
                        )
                        amountMetricCard(
                            label: "年度客户付款",
                            value: MoneyText.yuan(settlement.annualPaymentMilliYuan),
                            caption: settlement.mode == .batch ? "按批结清实收" : "按年回款到账",
                            color: Color(red: 0.18, green: 0.44, blue: 0.68)
                        )
                        amountMetricCard(
                            label: "截至年末累计未收",
                            value: MoneyText.yuan(settlement.outstandingAtYearEndMilliYuan),
                            caption: settlement.mode.title,
                            color: settlement.outstandingAtYearEndMilliYuan > 0 ? AppTheme.danger : AppTheme.success
                        )
                    }
                } else {
                    Text("请选择客户后查看年度结算。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }
        }
        .padding(13)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        )
    }

    private func amountMetricCard(label: String, value: String, caption: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(AppTheme.textMuted)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(caption)
                .font(.system(size: 9))
                .foregroundColor(AppTheme.textFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 70, alignment: .leading)
        .background(color.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.16), lineWidth: 1)
        )
    }

    private func employeeBalanceCaption(_ balance: Int64) -> String {
        if balance > 0 { return "年末未发" }
        if balance < 0 { return "年末预支 / 多发" }
        return "年末已发清"
    }

    private func metricCard(label: String, value: String, unit: String, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(primary ? Color.white.opacity(0.72) : AppTheme.textMuted)
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(primary ? .white : AppTheme.text)
                Text(unit)
                    .font(.system(size: 11))
                    .foregroundColor(primary ? Color.white.opacity(0.64) : AppTheme.textFaint)
            }
        }
        .padding(.horizontal, 15)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(primary ? AppTheme.navy : Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(primary ? Color.clear : AppTheme.line, lineWidth: 1)
        )
    }
    private var colorBreakdown: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("客户色数分类统计")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Text("按 1–5 色分别统计计酬工作量")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textFaint)
                Spacer()
            }
            HStack(spacing: 9) {
                ForEach(1...5, id: \.self) { color in
                    let colorRecords = customerPeriodRecords.filter { $0.colorCount == color }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("\(color) 色")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(colorFilter == color ? AppTheme.accentDark : AppTheme.text)
                            Spacer()
                            Text("\(colorRecords.count) 条")
                                .font(.system(size: 10))
                                .foregroundColor(AppTheme.textFaint)
                        }
                        Text("\(colorRecords.reduce(0) { $0 + $1.workload })")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundColor(AppTheme.text)
                        Text("计酬工作量")
                            .font(.system(size: 10))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(colorFilter == color ? AppTheme.accentSoft : Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(colorFilter == color ? AppTheme.accent : AppTheme.line, lineWidth: 1)
                    )
                }
            }
        }
    }
    private var reportTable: some View {
        VStack(spacing: 0) {
            tableHeader

            if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 27, weight: .light))
                        .foregroundColor(AppTheme.textFaint)
                        .frame(width: 58, height: 58)
                        .background(AppTheme.surfaceSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(AppTheme.line, lineWidth: 1)
                        )
                        .padding(.bottom, 6)
                    Text("暂无报表数据")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("请先提交正式账单，或调整筛选条件。")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 230)
                .padding(24)
            } else {
                ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                    tableRow(record, alternate: index.isMultiple(of: 2) == false)
                    if index < records.count - 1 {
                        Rectangle().fill(AppTheme.line).frame(height: 1).padding(.horizontal, 18)
                    }
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ReportTableWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(ReportTableWidthKey.self) { value in
            tableWidth = value
        }
    }

    private var columns: [ReportColumn] {
        switch mode {
        case .ledger: return [.date, .employee, .customer, .model, .quantity, .color, .workload, .receivable, .wage]
        case .employee: return [.date, .customer, .model, .quantity, .color, .workload, .wage]
        case .customer: return [.date, .employee, .model, .quantity, .color, .workload, .receivable]
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 10) {
            ForEach(columns) { column in
                Text(column.title)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AppTheme.textMuted)
                    .frame(width: columnWidth(column), alignment: columnAlignment(column))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Color(red: 0.98, green: 0.984, blue: 0.988))
        .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)
    }

    private func tableRow(_ record: QueryRecord, alternate: Bool) -> some View {
        HStack(spacing: 10) {
            ForEach(columns) { column in
                reportCell(record: record, column: column)
                    .frame(width: columnWidth(column), alignment: columnAlignment(column))
            }
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
        .background(alternate ? AppTheme.surfaceSoft.opacity(0.65) : Color.white)
    }

    private func reportCell(record: QueryRecord, column: ReportColumn) -> some View {
        Text(column.value(from: record))
            .font(.system(
                size: column == .model ? 13 : 12,
                weight: column.isAmount ? .bold : .regular,
                design: column == .date || column.isAmount ? .monospaced : .default
            ))
            .foregroundColor(column.isAmount ? AppTheme.text : AppTheme.textMuted)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
    }

    private func columnAlignment(_ column: ReportColumn) -> Alignment {
        switch column {
        case .quantity, .color, .workload, .receivable, .wage:
            return .trailing
        default:
            return .leading
        }
    }

    private func columnWidth(_ column: ReportColumn) -> CGFloat {
        let total = max(880, tableWidth - 36)
        let spacing: CGFloat = CGFloat(max(0, columns.count - 1)) * 10
        if column == .model {
            let fixed = columns.filter { $0 != .model }.reduce(CGFloat(0)) { $0 + baseColumnWidth($1) }
            return max(110, total - fixed - spacing)
        }
        return baseColumnWidth(column)
    }

    private func baseColumnWidth(_ column: ReportColumn) -> CGFloat {
        switch column {
        case .date: return 90
        case .employee: return mode == .ledger ? 82 : 100
        case .customer: return mode == .ledger ? 105 : 140
        case .model: return 110
        case .quantity: return 52
        case .color: return 48
        case .workload: return 82
        case .receivable: return 94
        case .wage: return 94
        }
    }

    private var totalWorkload: Int {
        records.reduce(0) { $0 + $1.workload }
    }

    private var groupMetricLabel: String {
        mode == .customer ? "员工数" : "客户数"
    }

    private var groupMetricValue: Int {
        switch mode {
        case .customer:
            return Set(records.map(\.employee).filter { !$0.isEmpty }).count
        default:
            return Set(records.map(\.customer).filter { !$0.isEmpty }).count
        }
    }

    private var resultTitle: String {
        switch mode {
        case .ledger: return "流水明细"
        case .employee: return "员工明细"
        case .customer: return "客户明细"
        }
    }

    private var resultDescription: String {
        switch mode {
        case .ledger:
            return "按日期倒序展示本机正式账单。"
        case .employee:
            return "展示所选员工在当前统计周期内的全部计件明细。"
        case .customer:
            return "展示所选客户在当前统计周期内的全部计件明细，并可按色数筛选。"
        }
    }

    private var resultCaption: String {
        switch mode {
        case .ledger:
            return "\(DateKey.string(from: ledgerStart)) 至 \(DateKey.string(from: ledgerEnd))"
        case .employee:
            return periodCaption(reference: employeeReferenceDate, period: selectedEmployeePeriod)
        case .customer:
            return periodCaption(reference: customerReferenceDate, period: selectedCustomerPeriod)
        }
    }
    private func exportCSV() {
        guard !records.isEmpty else {
            errorMessage = "当前筛选条件下没有可导出的明细。"
            return
        }
        do {
            let url = try CSVExporter.makeFile(records: records)
            shareItems = [url]
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func ensureSelections() {
        ensureEmployeeSelection()
        ensureCustomerSelection()
    }

    private func ensureYearSelection() {
        if !availableYears.contains(selectedYear) {
            selectedYear = availableYears.first ?? Calendar.current.component(.year, from: Date())
        }
    }

    private func applyYearToFilters() {
        let start = QueryView.yearStart(selectedYear)
        let end = QueryView.yearEnd(selectedYear)
        ledgerStart = start
        ledgerEnd = end
        employeeReferenceDate = start
        customerReferenceDate = start
    }

    private func ensureEmployeeSelection() {
        if employeeName.isEmpty || !store.allEmployeeNames.contains(employeeName) {
            employeeName = store.allEmployeeNames.first ?? ""
        }
    }

    private func ensureCustomerSelection() {
        if customerName.isEmpty || !store.allCustomerNames.contains(customerName) {
            customerName = store.allCustomerNames.first ?? ""
        }
    }

    private func periodBounds(reference: Date, period: ReportPeriod) -> (start: Date, inclusiveEnd: Date) {
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: reference)
        let start: Date
        let endExclusive: Date
        switch period {
        case .day:
            start = day
            endExclusive = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400)
        case .month:
            let components = calendar.dateComponents([.year, .month], from: day)
            start = calendar.date(from: components) ?? day
            endExclusive = calendar.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(86400 * 31)
        case .year:
            let components = calendar.dateComponents([.year], from: day)
            start = calendar.date(from: components) ?? day
            endExclusive = calendar.date(byAdding: .year, value: 1, to: start) ?? start.addingTimeInterval(86400 * 366)
        }
        let inclusiveEnd = calendar.date(byAdding: .second, value: -1, to: endExclusive) ?? endExclusive
        return (start, inclusiveEnd)
    }

    private func periodCaption(reference: Date, period: ReportPeriod) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        switch period {
        case .day:
            formatter.dateFormat = "yyyy年M月d日"
            return formatter.string(from: reference)
        case .month:
            formatter.dateFormat = "yyyy年M月"
            return formatter.string(from: reference)
        case .year:
            return "\(calendar.component(.year, from: reference))年"
        }
    }

    private static func yearStart(_ year: Int) -> Date {
        let calendar = Calendar.current
        let components = DateComponents(year: year, month: 1, day: 1)
        return calendar.date(from: components) ?? DateKey.startOfDay(Date())
    }

    private static func yearEnd(_ year: Int) -> Date {
        let calendar = Calendar.current
        let start = yearStart(year)
        let nextYear = calendar.date(byAdding: .year, value: 1, to: start) ?? start.addingTimeInterval(86400 * 366)
        return calendar.date(byAdding: .second, value: -1, to: nextYear) ?? nextYear
    }
}
private enum ReportMode: String, CaseIterable, Identifiable, Equatable {
    case ledger
    case employee
    case customer

    var id: String { rawValue }

    var tabTitle: String {
        switch self {
        case .ledger: return "原始流水台账"
        case .employee: return "员工统计"
        case .customer: return "客户统计"
        }
    }

    var scopeTitle: String { tabTitle }
}

private enum ReportPeriod: String, CaseIterable, Identifiable, Equatable, Hashable {
    case day
    case month
    case year

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "按日查询"
        case .month: return "按月查询"
        case .year: return "完整年度"
        }
    }

    var fieldLabel: String {
        switch self {
        case .day: return "日期"
        case .month: return "所属月份"
        case .year: return "所属年度"
        }
    }
}

private enum ReportColumn: String, CaseIterable, Identifiable, Equatable {
    case date
    case employee
    case customer
    case model
    case quantity
    case color
    case workload
    case receivable
    case wage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .date: return "日期"
        case .employee: return "员工"
        case .customer: return "客户"
        case .model: return "产品型号"
        case .quantity: return "数量"
        case .color: return "色数"
        case .workload: return "计酬工作量"
        case .receivable: return "客户应收"
        case .wage: return "员工工资"
        }
    }

    var isAmount: Bool {
        self == .receivable || self == .wage
    }

    func value(from record: QueryRecord) -> String {
        switch self {
        case .date: return DateKey.string(from: record.date)
        case .employee: return record.employee
        case .customer: return record.customer
        case .model: return record.model
        case .quantity: return String(record.quantity)
        case .color: return String(record.colorCount)
        case .workload: return String(record.workload)
        case .receivable: return MoneyText.yuan(record.receivableMilliYuan, empty: "—")
        case .wage: return MoneyText.yuan(record.wageMilliYuan, empty: "—")
        }
    }
}

private struct ReportTableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 900

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
