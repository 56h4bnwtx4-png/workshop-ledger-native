import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: AppStore

    let onNewEntry: () -> Void
    let onBackfill: () -> Void
    let onOpenDate: (Date) -> Void
    let onOpenSettings: () -> Void
    let onOpenReports: () -> Void

    private var days: [HomeDay] {
        let billMap = Dictionary(uniqueKeysWithValues: store.bills.map { (DateKey.string(from: $0.date), $0) })
        let draftMap = Dictionary(uniqueKeysWithValues: store.drafts.map { (DateKey.string(from: $0.date), $0) })
        let keys = Set(billMap.keys).union(draftMap.keys).sorted(by: >)
        return keys.compactMap { key in
            guard let date = DateKey.date(from: key) else { return nil }
            let draftRows = draftMap[key] == nil ? [] : store.draftRows(on: date)
            return HomeDay(date: date, bill: billMap[key], draft: draftMap[key], draftRows: draftRows)
        }
    }

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "车间计件流水账",
                brandSubtitle: "Workshop Ledger",
                brandIcon: "list.bullet.rectangle",
                leadingIcon: "gearshape",
                backAction: onOpenSettings
            ) {
                HStack(spacing: 10) {
                    TopIconButton(icon: "chart.bar.xaxis", action: onOpenReports)
                    TopIconButton(icon: "doc.badge.plus", action: onNewEntry, emphasized: true)
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    PageHeading(
                        eyebrow: "本地流水台账",
                        title: "全部账单",
                        note: "按日期倒序查看每一天的计件记录"
                    ) {
                        HStack(spacing: 10) {
                            Button(action: onBackfill) {
                                HStack(spacing: 7) {
                                    Image(systemName: "calendar.badge.plus")
                                    Text("补录")
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())

                            HStack(spacing: 4) {
                                Text("共")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppTheme.textMuted)
                                Text("\(days.count)")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(AppTheme.text)
                                Text("个账单日")
                                    .font(.system(size: 13))
                                    .foregroundColor(AppTheme.textMuted)
                            }
                            .padding(.horizontal, 13)
                            .frame(height: 34)
                            .background(AppTheme.surfaceSoft)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(AppTheme.line, lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 0)

                    billList

                    HStack {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(AppTheme.success)
                                .frame(width: 7, height: 7)
                            Text(store.cloudStatusText)
                        }
                        Spacer()
                        Text("数量 × 色数只用于计酬工作量统计")
                    }
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textFaint)
                    .padding(.top, 18)
                    .padding(.horizontal, 3)
                }
                .padding(.horizontal, 38)
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
        }
    }

    private var billList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                Text("日期")
                    .frame(width: 250, alignment: .leading)
                Text("当日账单摘要")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundColor(AppTheme.textFaint)
            .padding(.horizontal, 22)
            .frame(height: 45)
            .background(Color(red: 0.98, green: 0.984, blue: 0.988))
            .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

            if days.isEmpty {
                emptyState
            } else {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    Button {
                        onOpenDate(day.date)
                    } label: {
                        dayRow(day)
                    }
                    .buttonStyle(PlainButtonStyle())
                    if index < days.count - 1 {
                        Rectangle()
                            .fill(AppTheme.line)
                            .frame(height: 1)
                            .padding(.horizontal, 0)
                    }
                }
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.line, lineWidth: 1)
        )
    }

    private var emptyState: some View {
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
            Text("暂无账单")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(AppTheme.text)
            Text("点击右上角新建图标，开始录入第一条计件流水。")
                .font(.system(size: 13))
                .foregroundColor(AppTheme.textMuted)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 300)
        .padding(24)
    }

    private func dayRow(_ day: HomeDay) -> some View {
        HStack(spacing: 24) {
            HStack(spacing: 13) {
                calendarTile(for: day.date)
                VStack(alignment: .leading, spacing: 5) {
                    Text(DateKey.display(day.date))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text(weekday(day.date))
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textFaint)
                }
                if day.draft != nil {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.white, lineWidth: 2))
                        .shadow(color: AppTheme.accent.opacity(0.25), radius: 4)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 250, alignment: .leading)

            HStack(spacing: 24) {
                summaryText(for: day)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Color(red: 0.60, green: 0.64, blue: 0.69))
                    .frame(width: 32, height: 32)
                    .background(AppTheme.surfaceSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(AppTheme.line, lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 22)
        .frame(minHeight: 86)
        .contentShape(Rectangle())
    }

    private func summaryText(for day: HomeDay) -> some View {
        let useDraft = day.draft != nil
        let rows: [HomeSummaryRow]
        if useDraft {
            rows = day.draftRows.map {
                HomeSummaryRow(employee: $0.employee, customer: $0.customer, quantity: Int($0.quantity) ?? 0, colorCount: $0.colorCount)
            }
        } else {
            rows = (day.bill?.items ?? []).map {
                HomeSummaryRow(employee: $0.employee, customer: $0.customer, quantity: $0.quantity, colorCount: $0.colorCount)
            }
        }
        let workload = rows.reduce(0) { $0 + ($1.quantity * $1.colorCount) }
        let employeeCount = Set(rows.map(\.employee).filter { !$0.isEmpty }).count
        let customerCount = Set(rows.map(\.customer).filter { !$0.isEmpty }).count

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("计酬工作量 \(workload)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Circle().fill(Color(red: 0.78, green: 0.80, blue: 0.83)).frame(width: 3, height: 3)
                Text("\(employeeCount) 位员工")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.24, green: 0.28, blue: 0.34))
                Circle().fill(Color(red: 0.78, green: 0.80, blue: 0.83)).frame(width: 3, height: 3)
                Text("\(customerCount) 位客户")
                    .font(.system(size: 14))
                    .foregroundColor(Color(red: 0.24, green: 0.28, blue: 0.34))

                if useDraft {
                    StatusTag(
                        text: day.bill == nil ? "未提交草稿" : "草稿待提交",
                        foreground: AppTheme.accentDark,
                        background: AppTheme.accentSoft
                    )
                } else {
                    StatusTag(
                        text: "正式账单",
                        foreground: Color(red: 0.18, green: 0.46, blue: 0.35),
                        background: Color(red: 0.93, green: 0.97, blue: 0.95)
                    )
                    if store.isBillPending(day.date) {
                        StatusTag(
                            text: "待云端备份",
                            foreground: AppTheme.accentDark,
                            background: AppTheme.accentSoft
                        )
                    }
                }
            }
            if useDraft {
                Text("草稿只保存在本机，尚未生成正式账单")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.accentDark)
            }
        }
    }

    private func calendarTile(for date: Date) -> some View {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        return VStack(spacing: 0) {
            Text("\(month)月")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(AppTheme.navy)
            Text("\(day)")
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(AppTheme.text)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 46, height: 46)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(red: 0.84, green: 0.85, blue: 0.88), lineWidth: 1)
        )
        .shadow(color: AppTheme.navy.opacity(0.04), radius: 4, x: 0, y: 3)
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}

private struct HomeDay: Identifiable {
    let date: Date
    let bill: Bill?
    let draft: DraftSummary?
    let draftRows: [EntryRow]

    var id: String { DateKey.string(from: date) }
}

private struct HomeSummaryRow {
    let employee: String
    let customer: String
    let quantity: Int
    let colorCount: Int
}
