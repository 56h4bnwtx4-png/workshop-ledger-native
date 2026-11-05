import SwiftUI

struct EntryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase

    let onClose: () -> Void
    private let isBackfill: Bool

    @State private var billDate: Date
    @State private var hasSelectedDate: Bool
    @State private var rows: [EntryRow] = [EntryRow.empty()]
    @State private var source: EntrySource = .new
    @State private var originalDraftDate: Date?
    @State private var baselineSignature = EntrySignature(date: Date(), rows: [])
    @State private var editingBillID: Int64?
    @State private var didLoad = false
    @State private var didFinish = false
    @State private var tableWidth: CGFloat = 820
    @State private var activeAlert: EntryAlert?
    @State private var showDiscardConfirmation = false
    @State private var autoSaveWorkItem: DispatchWorkItem?
    @State private var showDatePicker = false
    @State private var modelSearchIndex: [ModelSearchEntry] = []

    init(initialDate: Date?, isBackfill: Bool = false, onClose: @escaping () -> Void) {
        let normalizedDate = DateKey.startOfDay(initialDate ?? Date())
        _billDate = State(initialValue: normalizedDate)
        _hasSelectedDate = State(initialValue: initialDate != nil)
        self.isBackfill = isBackfill
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            WorkshopShell {
            WorkshopTopBar(
                brandTitle: "计件录入",
                brandSubtitle: "Workshop Entry",
                brandIcon: "square.and.pencil",
                backAction: closeTapped
            ) {
                LocalModeBadge(text: store.cloudBadgeText)
            }

            if didLoad {
                ScrollView {
                    VStack(spacing: 0) {
                        heading
                        if hasSelectedDate && (hasChanges || source == .draft) {
                            draftNotice
                                .padding(.bottom, 18)
                        }
                        formCard
                        actionBar
                    }
                    .padding(.horizontal, 38)
                    .padding(.top, 30)
                    .padding(.bottom, 34)
                }
            } else {
                ProgressView("正在读取本机数据…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }

            if showDiscardConfirmation {
                discardConfirmation
            }
        }
        .onAppear(perform: loadInitialData)
        .onChange(of: currentSignature) { _ in scheduleAutoSave() }
        .onChange(of: scenePhase) { phase in
            if phase != .active {
                saveDraftIfNeeded()
            }
        }
        .onDisappear {
            if !didFinish {
                saveDraftIfNeeded()
            }
        }
        .sheet(isPresented: $showDatePicker) {
            BillDatePickerSheet(
                date: $billDate,
                maximumDate: DateKey.startOfDay(Date()),
                onComplete: { hasSelectedDate = true }
            )
        }
        .alert(item: $activeAlert) { item in
            switch item {

            case .overwrite:
                return Alert(
                    title: Text("该日期已有正式账单"),
                    message: Text("继续提交会用当前内容覆盖该日期原有的正式账单。"),
                    primaryButton: .destructive(Text("确认覆盖"), action: commitSubmission),
                    secondaryButton: .cancel(Text("取消"))
                )
            case .deleteBill:
                return Alert(
                    title: Text("删除当日账单？"),
                    message: Text("将永久删除 \(DateKey.display(billDate)) 的正式账单。删除后无法撤销，并会同步到云端。"),
                    primaryButton: .destructive(Text("确认删除"), action: deleteCurrentBill),
                    secondaryButton: .cancel(Text("取消"))
                )
            case .error(let message):
                return Alert(title: Text("无法完成操作"), message: Text(message), dismissButton: .default(Text("知道了")))
            }
        }
    }

    private var heading: some View {
        PageHeading(
            eyebrow: isBackfill || !hasSelectedDate ? "补录账单" : "当日账单",
            title: hasSelectedDate ? DateKey.display(billDate) : "请选择账单日期",
            note: hasSelectedDate
                ? (isEditingExistingBill
                    ? "\(weekday(billDate)) · 正式账单日期已锁定，避免误改到其他日期"
                    : "\(weekday(billDate)) · 点击账单日期可手动更改用于补记")
                : "点击账单日期选择要补录的历史日期，选好后再填写记录"
        ) {
            Button {
                showDatePicker = true
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 12) {
                        Text("账单日期")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(AppTheme.textFaint)
                        Spacer(minLength: 8)
                        HStack(spacing: 4) {
                            if isEditingExistingBill {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            Text(isEditingExistingBill ? "已锁定" : (hasSelectedDate ? "点击可更改" : "点击选择"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(isEditingExistingBill ? AppTheme.textMuted : AppTheme.accentDark)
                    }
                    Text(hasSelectedDate ? "\(DateKey.display(billDate)) · \(weekday(billDate))" : "请选择日期")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(hasSelectedDate ? AppTheme.text : AppTheme.textMuted)
                }
                .padding(.horizontal, 16)
                .frame(minWidth: 230, minHeight: 60, alignment: .leading)
                .background(AppTheme.surfaceSoft)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                )
                .opacity(isEditingExistingBill ? 0.88 : 1)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isEditingExistingBill)
        }
    }
    private var draftNotice: some View {
        HStack(alignment: .top, spacing: 13) {
            Text("!")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(.white)
                .frame(width: 21, height: 21)
                .background(AppTheme.accent)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("这是本地草稿，尚未生成为正式账单")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(AppTheme.accentDark)
                Text("请完成填写后点击页面底部的“提交”。草稿仅保存在当前设备。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer()
        }
        .padding(14)
        .background(AppTheme.accentSoft)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppTheme.accent.opacity(0.22), lineWidth: 1)
        )
    }

    private var formCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("计件记录")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("客户、员工从设置页维护的档案中选择；型号手动填写。加工单价按客户档案自动带出，应收金额 = 单价 × 数量 × 色数。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                        .lineSpacing(2)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

            VStack(spacing: 0) {
                tableHeader
                ForEach(Array(rows.indices), id: \.self) { index in
                    entryRow(index: index, alternate: index.isMultiple(of: 2) == false)
                    if index < rows.count - 1 {
                        Rectangle().fill(AppTheme.line).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: EntryTableWidthKey.self, value: proxy.size.width)
            })
            .onPreferenceChange(EntryTableWidthKey.self) { value in
                tableWidth = value
            }

            HStack {
                Text("共 \(rows.count) 行记录")
                Spacer()
                Text("客户、员工选项来自设置页本地档案")
            }
            .font(.system(size: 12))
            .foregroundColor(AppTheme.textFaint)
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(AppTheme.surfaceSoft)
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .top)

            Button(action: addRow) {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                    Text("增加一行")
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.white)
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        )
    }

    private var tableHeader: some View {
        HStack(spacing: columnSpacing) {
            headerCell("客户", width: columnWidths.customer)
            headerCell("员工", width: columnWidths.employee)
            headerCell("型号", width: columnWidths.model)
            headerCell("数量", width: columnWidths.quantity)
            headerCell("色数", width: columnWidths.colorAndDelete)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color(red: 0.98, green: 0.984, blue: 0.988))
    }

    private func entryRow(index: Int, alternate: Bool) -> some View {
        HStack(alignment: .top, spacing: columnSpacing) {
            customerPicker(row: $rows[index])
                .frame(width: columnWidths.customer)
                .disabled(rows[index].isLocked)
            employeePicker(row: $rows[index])
                .frame(width: columnWidths.employee)
                .disabled(rows[index].isLocked)
            ModelAutocompleteField(
                text: $rows[index].model,
                suggestions: modelSuggestions(for: rows[index].model)
            )
            .frame(width: columnWidths.model)
            .disabled(rows[index].isLocked)

            TextField("请输入数量", text: $rows[index].quantity)
                .keyboardType(.numberPad)
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 11)
                .frame(width: columnWidths.quantity, height: 44)
                .background(Color.white)
                .overlay(cellBorder)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: rows[index].quantity) { newValue in
                    let filtered = String(newValue.filter { $0.isNumber }.prefix(9))
                    if filtered != newValue {
                        rows[index].quantity = filtered
                    }
                }
                .disabled(rows[index].isLocked)

            HStack(spacing: 8) {
                Menu {
                    ForEach(1...5, id: \.self) { color in
                        Button {
                            rows[index].colorCount = color
                        } label: {
                            if rows[index].colorCount == color {
                                Label("\(color) 色", systemImage: "checkmark")
                            } else {
                                Text("\(color) 色")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("\(rows[index].colorCount)")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .foregroundColor(AppTheme.text)
                    .padding(.horizontal, 11)
                    .frame(height: 44)
                    .background(Color.white)
                    .overlay(cellBorder)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .frame(width: columnWidths.color)
                .disabled(rows[index].isLocked)

                Button(action: { deleteRow(at: index) }) {
                    Image(systemName: rows[index].isLocked ? "lock.fill" : "trash")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(rows[index].isLocked ? AppTheme.textMuted : AppTheme.danger)
                        .frame(width: columnWidths.deleteAction, height: 44)
                        .background(rows[index].isLocked ? AppTheme.surfaceSoft : AppTheme.dangerSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(rows[index].isLocked)
            }
            .frame(width: columnWidths.colorAndDelete)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            rows[index].isLocked
                ? Color(red: 0.955, green: 0.965, blue: 0.970)
                : (alternate ? Color(red: 0.985, green: 0.987, blue: 0.991) : Color.white)
        )
    }

    private var actionBar: some View {
        HStack(spacing: 20) {
            HStack(spacing: 14) {
                if isEditingExistingBill && !canDiscard {
                    Button(action: requestDeleteBill) {
                        HStack(spacing: 7) {
                            Image(systemName: "trash")
                            Text("删除当日账单")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 15)
                        .frame(height: 40)
                        .background(AppTheme.danger)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contentShape(Rectangle())
                } else {
                    Button(action: requestDiscard) {
                        HStack(spacing: 7) {
                            Image(systemName: "trash")
                            Text("放弃草稿")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(canDiscard ? AppTheme.danger : AppTheme.textFaint)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .disabled(!canDiscard)
                }

                Text(saveStateText)
                    .font(.system(size: 12))
                    .foregroundColor(hasChanges ? AppTheme.accentDark : AppTheme.textFaint)
            }
            Spacer()
            Button(action: submitTapped) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                    Text("提交")
                }
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .frame(height: 46)
                .background(AppTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: AppTheme.accent.opacity(0.22), radius: 9, x: 0, y: 7)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.top, 18)
    }
    private func customerPicker(row: Binding<EntryRow>) -> some View {
        directoryPicker(
            selection: row.customer,
            options: store.allCustomerNames,
            placeholder: store.allCustomerNames.isEmpty ? "暂无客户，请先到设置页添加" : "请选择客户"
        )
    }

    private func employeePicker(row: Binding<EntryRow>) -> some View {
        directoryPicker(
            selection: row.employee,
            options: store.allEmployeeNames,
            placeholder: store.allEmployeeNames.isEmpty ? "暂无员工，请先到设置页添加" : "请选择员工"
        )
    }

    private func directoryPicker(
        selection: Binding<String>,
        options: [String],
        placeholder: String
    ) -> some View {
        let selected = selection.wrappedValue
        let label = selected.isEmpty ? placeholder : selected

        return Menu {
            Button {
                selection.wrappedValue = ""
            } label: {
                if selected.isEmpty {
                    Label(placeholder, systemImage: "checkmark")
                } else {
                    Text(placeholder)
                }
            }

            ForEach(options, id: \.self) { name in
                Button {
                    selection.wrappedValue = name
                } label: {
                    if selected == name {
                        Label(name, systemImage: "checkmark")
                    } else {
                        Text(name)
                    }
                }
            }
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppTheme.text)
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .background(Color.white)
                .overlay(cellBorder)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(options.isEmpty && selected.isEmpty)
    }

    private func headerCell(_ title: String, width: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text("*")
                .foregroundColor(AppTheme.accent)
            Text(title)
                .foregroundColor(AppTheme.textMuted)
        }
        .font(.system(size: 12, weight: .bold))
        .frame(width: width, alignment: .leading)
    }

    private var cellBorder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
    }

    private var columnSpacing: CGFloat { 8 }

    private var columnWidths: EntryColumnWidths {
        let total = max(720, tableWidth - 20)
        let customerColumn = floor(total * 0.20)
        let employeeColumn = floor(total * 0.18)
        let quantityWidth: CGFloat = 92
        let colorWidth: CGFloat = 64
        let deleteWidth: CGFloat = 40
        let colorGroupWidth = colorWidth + 8 + deleteWidth
        let modelColumn = max(
            220,
            total - customerColumn - employeeColumn - quantityWidth - colorGroupWidth - columnSpacing * 4
        )
        return EntryColumnWidths(
            customer: customerColumn,
            employee: employeeColumn,
            model: modelColumn,
            quantity: quantityWidth,
            color: colorWidth,
            deleteAction: deleteWidth,
            colorAndDelete: colorGroupWidth
        )
    }

    private var currentRowsForDraft: [EntryRow] {
        rows.map { row in
            var copy = row
            copy.customer = copy.customer.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.employee = copy.employee.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.model = copy.model.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.quantity = copy.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.colorCount = Swift.min(5, Swift.max(1, copy.colorCount))
            return copy
        }
        .filter(\.hasEntryData)
    }

    private var currentSignature: EntrySignature {
        EntrySignature(date: billDate, rows: currentRowsForDraft)
    }

    private var hasChanges: Bool {
        didLoad && currentSignature != baselineSignature
    }

    private var isEditingExistingBill: Bool {
        guard let editingBillID else { return false }
        return store.bill(on: billDate)?.id == editingBillID
    }
    private var canDiscard: Bool {
        hasSelectedDate && (source == .draft || store.draft(on: billDate) != nil || hasChanges)
    }

    private var saveStateText: String {
        if !hasSelectedDate { return "请先选择账单日期" }
        if hasChanges { return "正在等待自动保存…" }
        if source == .draft { return "草稿已保存到本机" }
        if source == .bill { return "正式账单；只有实际修改后才会生成草稿" }
        return "编辑后将自动保存到本机"
    }

    private var minimumDate: Date {
        Calendar.current.date(byAdding: .year, value: -20, to: DateKey.startOfDay(Date())) ?? .distantPast
    }

    private func loadInitialData() {
        guard !didLoad else { return }
        rebuildModelSearchIndex()
        editingBillID = hasSelectedDate ? store.bill(on: billDate)?.id : nil
        if !hasSelectedDate {
            rows = [EntryRow.empty()]
            source = .new
            originalDraftDate = nil
            baselineSignature = EntrySignature(date: billDate, rows: [])
            didLoad = true
            return
        }
        let loaded = store.loadRows(for: billDate)
        rows = loaded.rows.isEmpty
            ? [EntryRow.empty(customer: store.allCustomerNames.first ?? "", employee: store.allEmployeeNames.first ?? "")]
            : loaded.rows
        source = loaded.source
        originalDraftDate = loaded.source == .draft ? billDate : nil
        baselineSignature = EntrySignature(date: billDate, rows: currentRowsForDraft)
        didLoad = true
    }

    private func addRow() {
        let previous = rows.last
        rows.append(
            EntryRow.empty(
                customer: previous?.customer ?? "",
                employee: previous?.employee ?? ""
            )
        )
    }

    private func deleteRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
        if rows.isEmpty {
            rows = [EntryRow.empty()]
        }
    }

    private func rebuildModelSearchIndex() {
        modelSearchIndex = store.allModelNames.compactMap { name in
            let normalized = normalizedModelSearchText(name)
            guard !normalized.isEmpty else { return nil }
            return ModelSearchEntry(name: name, normalizedName: normalized, length: normalized.count)
        }
    }

    private func modelSuggestions(for text: String) -> [String] {
        let query = normalizedModelSearchText(text)
        guard query.count >= 2 else { return [] }

        return modelSearchIndex
            .compactMap { entry -> ModelSuggestionCandidate? in
                guard let match = entry.normalizedName.range(of: query) else { return nil }
                let rank: Int
                if entry.normalizedName == query {
                    rank = 0
                } else if match.lowerBound == entry.normalizedName.startIndex {
                    rank = 1
                } else {
                    rank = 2
                }
                return ModelSuggestionCandidate(name: entry.name, rank: rank, length: entry.length)
            }
            .sorted { left, right in
                if left.rank != right.rank { return left.rank < right.rank }
                if left.length != right.length { return left.length < right.length }
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            .prefix(4)
            .map(\.name)
    }

    private func normalizedModelSearchText(_ text: String) -> String {
        let folded = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .widthInsensitive],
                locale: Locale(identifier: "zh_CN")
            )
        return folded
            .replacingOccurrences(of: "‐", with: "-")
            .replacingOccurrences(of: "‑", with: "-")
            .replacingOccurrences(of: "‒", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "−", with: "-")
    }

    private func scheduleAutoSave() {
        guard didLoad, !didFinish else { return }
        autoSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            saveDraftIfNeeded()
        }
        autoSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: workItem)
    }

    private func saveDraftIfNeeded() {
        guard didLoad, !didFinish, hasSelectedDate else { return }
        let signature = currentSignature
        let rowsToSave = currentRowsForDraft
        let existingBill = store.bill(on: billDate)
        let matchesExistingBill = existingBill.map {
            rowsToSave.matchesBillItems($0.items)
        } ?? false
        let shouldClearDraft = rowsToSave.isEmpty || matchesExistingBill

        if source == .draft,
           let previousDate = originalDraftDate,
           DateKey.string(from: previousDate) != DateKey.string(from: billDate) {
            store.deleteDraft(date: previousDate)
        }

        if shouldClearDraft {
            autoSaveWorkItem?.cancel()
            store.deleteDraft(date: billDate)
            originalDraftDate = nil
            source = existingBill == nil ? .new : .bill
            baselineSignature = signature
            return
        }

        guard signature != baselineSignature else { return }
        autoSaveWorkItem?.cancel()
        store.saveDraft(date: billDate, rows: rowsToSave)
        source = .draft
        originalDraftDate = billDate
        baselineSignature = signature
    }

    private func closeTapped() {
        saveDraftIfNeeded()
        finishAndClose()
    }

    private var discardConfirmation: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { showDiscardConfirmation = false }

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.danger)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.dangerSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("确认放弃草稿？")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text("将清除当前日期的本地临时草稿。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                }

                Text("将清除此日期保存在本机的临时草稿，并恢复为最近一次正式账单或空白录入。此操作不能撤销。")
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.textMuted)
                    .lineSpacing(3)

                HStack(spacing: 12) {
                    Spacer()
                    Button("取消") { showDiscardConfirmation = false }
                        .buttonStyle(SecondaryButtonStyle())
                    Button {
                        discardDraft()
                        showDiscardConfirmation = false
                    } label: {
                        Text("确认放弃")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(AppTheme.danger)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(24)
            .frame(maxWidth: 470)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(AppTheme.line, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.18), radius: 24, x: 0, y: 12)
            .padding(24)
        }
        .zIndex(50)
    }

    private func requestDiscard() {
        guard canDiscard else { return }
        showDiscardConfirmation = true
    }

    private func requestDeleteBill() {
        guard isEditingExistingBill, !canDiscard else { return }
        guard let bill = store.bill(on: billDate) else {
            activeAlert = .error("没有找到该日期的正式账单，请返回主页刷新后重试。")
            return
        }
        guard !bill.items.contains(where: { $0.settlementBatchID != nil }) else {
            activeAlert = .error("该账单包含已结清流水，不能删除。请先撤销对应结清批次。")
            return
        }
        activeAlert = .deleteBill
    }

    private func deleteCurrentBill() {
        autoSaveWorkItem?.cancel()
        do {
            try store.deleteBill(date: billDate)
            didFinish = true
            onClose()
        } catch {
            activeAlert = .error(error.localizedDescription)
        }
    }
    private func discardDraft() {
        autoSaveWorkItem?.cancel()
        if source == .draft, let previousDate = originalDraftDate {
            store.deleteDraft(date: previousDate)
        }
        store.deleteDraft(date: billDate)
        originalDraftDate = nil

        let loaded = store.loadRows(for: billDate)
        rows = loaded.rows.isEmpty
            ? [EntryRow.empty(customer: store.allCustomerNames.first ?? "", employee: store.allEmployeeNames.first ?? "")]
            : loaded.rows
        source = loaded.source
        originalDraftDate = loaded.source == .draft ? billDate : nil
        baselineSignature = EntrySignature(date: billDate, rows: currentRowsForDraft)
    }

    private func submitTapped() {
        guard hasSelectedDate else {
            activeAlert = .error("请先选择账单日期。")
            return
        }

        if let editingBillID,
           store.bill(on: billDate)?.id != editingBillID {
            activeAlert = .error("正式账单日期已锁定，不能改到其他日期。")
            return
        }

        let candidate = rows.map { row in
            var copy = row
            copy.customer = copy.customer.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.employee = copy.employee.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.model = copy.model.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.quantity = copy.quantity.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
        .filter { !$0.model.isEmpty || !$0.quantity.isEmpty || !$0.customer.isEmpty || !$0.employee.isEmpty }

        guard !candidate.isEmpty else {
            activeAlert = .error("请至少填写一条计件记录。")
            return
        }
        if let existingBill = store.bill(on: billDate),
           candidate.matchesBillItems(existingBill.items) {
            store.deleteDraft(date: billDate)
            guard store.draft(on: billDate) == nil else {
                store.lastError = store.lastError ?? "无法清理重复草稿，请重试。"
                return
            }
            finishAndClose()
            return
        }
        if let missing = candidate.first(where: { $0.customer.isEmpty }) {
            activeAlert = .error("第 \(candidate.firstIndex(of: missing).map { $0 + 1 } ?? 1) 条记录尚未选择客户。")
            return
        }
        if let missing = candidate.first(where: { $0.employee.isEmpty }) {
            activeAlert = .error("第 \(candidate.firstIndex(of: missing).map { $0 + 1 } ?? 1) 条记录尚未选择员工。")
            return
        }
        if let missing = candidate.first(where: { $0.model.isEmpty }) {
            activeAlert = .error("第 \(candidate.firstIndex(of: missing).map { $0 + 1 } ?? 1) 条记录的型号为空。")
            return
        }
        if let invalid = candidate.first(where: { $0.quantityValue == nil }) {
            activeAlert = .error("第 \(candidate.firstIndex(of: invalid).map { $0 + 1 } ?? 1) 条记录的数量必须是正整数。")
            return
        }
        if let missingPrice = candidate.first(where: {
            !$0.isLocked
                && $0.storedUnitPriceMilliYuan == nil
                && store.unitPriceMilliYuan(forCustomer: $0.customer) == nil
        }) {
            let index = candidate.firstIndex(of: missingPrice).map { $0 + 1 } ?? 1
            activeAlert = .error("第 \(index) 条记录的客户“\(missingPrice.customer)”尚未设置加工单价，请先到客户管理页设置。")
            return
        }
        if let missingWage = candidate.first(where: {
            !$0.isLocked
                && $0.storedEmployeeWageMilliYuan == nil
                && store.wageMilliYuan(forEmployee: $0.employee) == nil
        }) {
            let index = candidate.firstIndex(of: missingWage).map { $0 + 1 } ?? 1
            activeAlert = .error("第 \(index) 条记录的员工“\(missingWage.employee)”尚未设置工资单价，请先到员工管理页设置。")
            return
        }

        if DateKey.string(from: billDate) != baselineSignature.dateKey,
           store.bill(on: billDate) != nil {
            activeAlert = .overwrite
        } else {
            commitSubmission()
        }
    }

    private func commitSubmission() {
        do {
            _ = try store.submitBill(date: billDate, rows: rows)
            autoSaveWorkItem?.cancel()
            didFinish = true
            onClose()
        } catch {
            store.lastError = error.localizedDescription
        }
    }

    private func finishAndClose() {
        autoSaveWorkItem?.cancel()
        didFinish = true
        onClose()
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}

private enum EntryAlert: Identifiable {
    case overwrite
    case deleteBill
    case error(String)

    var id: String {
        switch self {
        case .overwrite: return "overwrite"
        case .deleteBill: return "delete-bill"
        case .error(let message): return "error-\(message)"
        }
    }
}

private struct EntrySignature: Equatable {
    let dateKey: String
    let rows: [EntrySignatureRow]

    init(date: Date, rows: [EntryRow]) {
        dateKey = DateKey.string(from: date)
        self.rows = rows.map {
            EntrySignatureRow(
                customer: $0.customer,
                employee: $0.employee,
                model: $0.model,
                quantity: $0.quantity,
                colorCount: $0.colorCount
            )
        }
    }
}

private struct EntrySignatureRow: Equatable {
    let customer: String
    let employee: String
    let model: String
    let quantity: String
    let colorCount: Int
}

private struct ModelSearchEntry {
    let name: String
    let normalizedName: String
    let length: Int
}

private struct ModelSuggestionCandidate {
    let name: String
    let rank: Int
    let length: Int
}

private struct EntryColumnWidths {
    let customer: CGFloat
    let employee: CGFloat
    let model: CGFloat
    let quantity: CGFloat
    let color: CGFloat
    let deleteAction: CGFloat
    let colorAndDelete: CGFloat
}

private struct EntryTableWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 820

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ModelAutocompleteField: View {
    @Binding var text: String
    let suggestions: [String]
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("请输入产品型号", text: $text)
                .font(.system(size: 15, weight: .medium))
                .disableAutocorrection(true)
                .autocapitalization(.none)
                .focused($focused)
                .padding(.horizontal, 11)
                .frame(height: 44)
                .background(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { focused = false }

            if focused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                        Button {
                            text = suggestion
                            focused = false
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 11))
                                    .foregroundColor(AppTheme.textFaint)
                                Text(suggestion)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(AppTheme.text)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PlainButtonStyle())
                        if index < suggestions.count - 1 {
                            Rectangle().fill(AppTheme.line).frame(height: 1)
                        }
                    }
                }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
                )
            }
        }
    }
}

private struct BillDatePickerSheet: View {
    @Binding var date: Date
    let maximumDate: Date
    let onComplete: () -> Void
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("修改账单日期")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("只允许选择今天或过去的日期，用于补记账目。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Button("完成") {
                    onComplete()
                    presentationMode.wrappedValue.dismiss()
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.accentDark)
            }

            DatePicker(
                "账单日期",
                selection: $date,
                in: Date.distantPast...maximumDate,
                displayedComponents: .date
            )
            .datePickerStyle(WheelDatePickerStyle())
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 330)
        .background(AppTheme.background)
    }
}
