import SwiftUI

struct DirectoryView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var activeKind: DirectoryKind = .customer
    @State private var activeSheet: DirectorySheetItem?
    @State private var deleteTarget: DirectoryDeleteTarget?

    private var members: [DirectoryMember] {
        switch activeKind {
        case .customer:
            return store.customers.map {
                DirectoryMember(id: $0.id, name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            }
        case .employee:
            return store.employees.map {
                DirectoryMember(id: $0.id, name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            }
        }
    }

    var body: some View {
        ZStack {
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
                    VStack(spacing: 0) {
                        PageHeading(
                            eyebrow: "基础档案",
                            title: "设置管理",
                            note: "客户与员工档案保存在当前账号，并同步到该账号的云端备份；录入页会读取最新档案。"
                        ) {
                            PageScopeBadge(label: "本期仅配置", value: "客户 · 员工")
                        }

                        settingsCard
                        cloudCard
                            .padding(.top, 18)
                    }
                    .padding(.horizontal, 38)
                    .padding(.top, 30)
                    .padding(.bottom, 34)
                }
            }

            if let target = deleteTarget {
                deleteConfirmation(target)
            }
        }
        .sheet(item: $activeSheet) { item in
            switch item {
            case .editor(let kind, let member):
                DirectoryEditorSheet(
                    kind: kind,
                    member: member,
                    onSave: { name in
                        try save(kind: kind, existing: member, name: name)
                    }
                )
            case .detail(let kind, let member):
                DirectoryDetailSheet(kind: kind, member: member)
            case .cloud:
                CloudBackupView {
                    activeSheet = nil
                }
            }
        }
    }

    private func deleteConfirmation(_ target: DirectoryDeleteTarget) -> some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { deleteTarget = nil }

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 13) {
                    Image(systemName: "trash")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.danger)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.dangerSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("确认删除\(target.kind.singular)？")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text("档案删除后不能撤销。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                }

                Text("删除后，该档案将不再出现在录入页下拉选项中。已有流水中的名称不会被改动。")
                    .font(.system(size: 14))
                    .foregroundColor(AppTheme.textMuted)
                    .lineSpacing(3)

                HStack(spacing: 12) {
                    Spacer()
                    Button("取消") { deleteTarget = nil }
                        .buttonStyle(SecondaryButtonStyle())
                    Button {
                        delete(target)
                        deleteTarget = nil
                    } label: {
                        Text("确认删除")
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
            .shadow(color: AppTheme.navy.opacity(0.18), radius: 24, x: 0, y: 12)
            .padding(30)
        }
        .zIndex(20)
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                settingsTab(kind: .customer, count: store.customers.count, icon: "person.2")
                settingsTab(kind: .employee, count: store.employees.count, icon: "person.crop.circle")
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 62)
            .background(AppTheme.surfaceSoft)
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(activeKind.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text(activeKind.description)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
                Spacer()
                Button {
                    activeSheet = .editor(activeKind, nil)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                        Text("新增\(activeKind.singular)")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

            directoryTable

            HStack {
                Text("\(activeKind.singular)档案共 \(members.count) 条")
                Spacer()
                Text("录入页打开时会读取最新档案")
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

    private var cloudCard: some View {
        Panel {
            HStack(spacing: 16) {
                Image(systemName: store.isCloudLoggedIn ? "icloud.fill" : "icloud.slash")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(store.isCloudLoggedIn ? AppTheme.success : AppTheme.textFaint)
                    .frame(width: 48, height: 48)
                    .background(store.isCloudLoggedIn ? Color(red: 0.93, green: 0.97, blue: 0.95) : AppTheme.surfaceSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text("云端备份与恢复")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text(store.cloudStatusText)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                    if let snapshot = store.lastCloudSnapshotName {
                        Text("最近快照：\(snapshot)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button {
                    activeSheet = .cloud
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "icloud.and.arrow.up")
                        Text("账号、设备与云端备份")
                    }
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(20)
        }
    }

    private func settingsTab(kind: DirectoryKind, count: Int, icon: String) -> some View {
        Button {
            activeKind = kind
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                Text(kind.tabTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(activeKind == kind ? .white : AppTheme.textMuted)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background(activeKind == kind ? AppTheme.accent : Color.white)
                    .clipShape(Capsule())
            }
            .foregroundColor(activeKind == kind ? AppTheme.accentDark : AppTheme.textMuted)
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(activeKind == kind ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(activeKind == kind ? AppTheme.line : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.trailing, 7)
    }

    private var directoryTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("档案名称")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("创建时间")
                    .frame(width: 150, alignment: .leading)
                Text("最近修改")
                    .frame(width: 150, alignment: .leading)
                Text("操作")
                    .frame(width: 112, alignment: .trailing)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(AppTheme.textMuted)
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(Color(red: 0.98, green: 0.984, blue: 0.988))
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

            if members.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
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
                    Text("暂无\(activeKind.singular)档案")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("点击右上角“新增\(activeKind.singular)”创建第一条档案。")
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 260)
                .padding(24)
            } else {
                ForEach(Array(members.enumerated()), id: \.element.id) { index, member in
                    memberRow(member, alternate: index.isMultiple(of: 2) == false)
                    if index < members.count - 1 {
                        Rectangle().fill(AppTheme.line).frame(height: 1).padding(.horizontal, 22)
                    }
                }
            }
        }
    }

    private func memberRow(_ member: DirectoryMember, alternate: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: activeKind == .customer ? "building.2" : "person.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.accentDark)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(member.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatTime(member.createdAt))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 150, alignment: .leading)

            Text(formatTime(member.updatedAt))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(AppTheme.textMuted)
                .frame(width: 150, alignment: .leading)

            HStack(spacing: 7) {
                rowAction(icon: "eye", color: AppTheme.textMuted) {
                    activeSheet = .detail(activeKind, member)
                }
                rowAction(icon: "pencil", color: AppTheme.accentDark) {
                    activeSheet = .editor(activeKind, member)
                }
                rowAction(icon: "trash", color: AppTheme.danger) {
                    deleteTarget = DirectoryDeleteTarget(kind: activeKind, member: member)
                }
            }
            .frame(width: 112, alignment: .trailing)
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 58)
        .background(alternate ? AppTheme.surfaceSoft.opacity(0.7) : Color.white)
    }

    private func rowAction(icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 30, height: 30)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                )
        }
        .contentShape(Rectangle())
        .buttonStyle(PlainButtonStyle())
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func save(kind: DirectoryKind, existing: DirectoryMember?, name: String) throws {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DirectoryValidationError.emptyName }
        guard value.count <= 40 else { throw DirectoryValidationError.tooLong }

        do {
            switch (kind, existing) {
            case (.customer, nil):
                try store.addCustomer(name: value)
            case (.customer, let member?):
                guard let customer = store.customers.first(where: { $0.id == member.id }) else {
                    throw DirectoryValidationError.notFound
                }
                try store.updateCustomer(customer, name: value)
            case (.employee, nil):
                try store.addEmployee(name: value)
            case (.employee, let member?):
                guard let employee = store.employees.first(where: { $0.id == member.id }) else {
                    throw DirectoryValidationError.notFound
                }
                try store.updateEmployee(employee, name: value)
            }
        } catch {
            let message = error.localizedDescription
            if message.lowercased().contains("unique") {
                throw DirectoryValidationError.duplicate
            }
            throw error
        }
    }

    private func delete(_ target: DirectoryDeleteTarget) {
        do {
            switch target.kind {
            case .customer:
                guard let customer = store.customers.first(where: { $0.id == target.member.id }) else { return }
                try store.deleteCustomer(customer)
            case .employee:
                guard let employee = store.employees.first(where: { $0.id == target.member.id }) else { return }
                try store.deleteEmployee(employee)
            }
        } catch {
            store.lastError = error.localizedDescription
        }
    }
}

private enum DirectoryKind: Equatable {
    case customer
    case employee

    var singular: String {
        switch self {
        case .customer: return "客户"
        case .employee: return "员工"
        }
    }

    var tabTitle: String {
        "\(singular)管理"
    }

    var title: String {
        "\(singular)管理"
    }

    var description: String {
        switch self {
        case .customer: return "录入页的客户下拉选项来自此处维护的档案。"
        case .employee: return "录入页的员工下拉选项来自此处维护的档案。"
        }
    }
}

private struct DirectoryMember: Identifiable {
    let id: Int64
    let name: String
    let createdAt: Date
    let updatedAt: Date
}

private enum DirectorySheetItem: Identifiable {
    case editor(DirectoryKind, DirectoryMember?)
    case detail(DirectoryKind, DirectoryMember)
    case cloud

    var id: String {
        switch self {
        case .editor(let kind, let member):
            return "editor-\(kind.singular)-\(member?.id ?? 0)"
        case .detail(let kind, let member):
            return "detail-\(kind.singular)-\(member.id)"
        case .cloud:
            return "cloud"
        }
    }
}

private struct DirectoryDeleteTarget: Identifiable {
    let kind: DirectoryKind
    let member: DirectoryMember

    var id: String { "\(kind.singular)-\(member.id)" }
}

private enum DirectoryValidationError: LocalizedError {
    case emptyName
    case tooLong
    case duplicate
    case notFound

    var errorDescription: String? {
        switch self {
        case .emptyName: return "名称不能为空。"
        case .tooLong: return "名称最多 40 个字符。"
        case .duplicate: return "该名称已存在，请使用其他名称。"
        case .notFound: return "该档案已不存在，请刷新后重试。"
        }
    }
}

private struct DirectoryEditorSheet: View {
    let kind: DirectoryKind
    let member: DirectoryMember?
    let onSave: (String) throws -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var name: String
    @State private var errorMessage = ""

    init(kind: DirectoryKind, member: DirectoryMember?, onSave: @escaping (String) throws -> Void) {
        self.kind = kind
        self.member = member
        self.onSave = onSave
        _name = State(initialValue: member?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "pencil")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.accentDark)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(member == nil ? "新增" : "编辑")\(kind.singular)")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("保存后立即用于计件录入页下拉选项。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("\(kind.singular)名称")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(AppTheme.textMuted)
                TextField("请输入\(kind.singular)名称", text: $name)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(errorMessage.isEmpty ? AppTheme.line : AppTheme.danger, lineWidth: 1)
                    )
                    .onChange(of: name) { _ in errorMessage = "" }
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.danger)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("取消") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("保存") {
                    do {
                        try onSave(name)
                        presentationMode.wrappedValue.dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .frame(minWidth: 430, minHeight: 280)
        .background(AppTheme.background)
    }
}

private struct DirectoryDetailSheet: View {
    let kind: DirectoryKind
    let member: DirectoryMember
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 13) {
                Image(systemName: "eye")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.success)
                    .frame(width: 46, height: 46)
                    .background(Color(red: 0.93, green: 0.97, blue: 0.95))
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(kind.singular)档案")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text("档案信息只保存在本机。")
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textMuted)
                }
            }

            detailRow(label: "名称", value: member.name)
            detailRow(label: "档案编号", value: String(member.id))
            detailRow(label: "创建时间", value: formatTime(member.createdAt))
            detailRow(label: "最近修改", value: formatTime(member.updatedAt))

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("关闭") {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(24)
        .frame(minWidth: 430, minHeight: 330)
        .background(AppTheme.background)
    }

    private func detailRow(label: String, value: String) -> some View {
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

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
