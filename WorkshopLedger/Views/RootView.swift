import SwiftUI

enum AppSection {
    case bills
    case entry
    case directory
    case query
}

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var section: AppSection = .bills
    @State private var entryDate: Date? = DateKey.startOfDay(Date())
    @State private var entryIsBackfill = false
    @State private var entryReloadID = UUID()

    var body: some View {
        Group {
            switch section {
            case .bills:
                HomeView(
                    onNewEntry: openTodayEntry,
                    onBackfill: openBackfillEntry,
                    onOpenDate: openEntry,
                    onOpenSettings: { section = .directory },
                    onOpenReports: { section = .query }
                )
            case .entry:
                EntryView(initialDate: entryDate, isBackfill: entryIsBackfill) {
                    store.reloadAll()
                    section = .bills
                }
                .id(entryReloadID)
            case .directory:
                DirectoryView { section = .bills }
            case .query:
                QueryView { section = .bills }
            }
        }
        .task {
            await store.applicationBecameActive()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await store.applicationBecameActive() }
            }
        }
        .alert(isPresented: errorBinding) {
            Alert(
                title: Text("本机数据错误"),
                message: Text(store.lastError ?? "未知错误"),
                dismissButton: .default(Text("知道了")) { store.lastError = nil }
            )
        }
    }

    private func openTodayEntry() {
        entryDate = DateKey.startOfDay(Date())
        entryIsBackfill = false
        entryReloadID = UUID()
        section = .entry
    }

    private func openBackfillEntry() {
        entryDate = nil
        entryIsBackfill = true
        entryReloadID = UUID()
        section = .entry
    }

    private func openEntry(_ date: Date) {
        entryDate = DateKey.startOfDay(date)
        entryIsBackfill = false
        entryReloadID = UUID()
        section = .entry
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )
    }
}