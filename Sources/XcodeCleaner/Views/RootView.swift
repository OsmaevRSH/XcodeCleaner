import SwiftUI
import XcodeCleanerCore

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: sectionBinding) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(160)
        } detail: {
            VStack(spacing: 0) {
                DiskHeaderView(disk: model.scan.disk, bytesToFree: model.bytesToFree, lastReport: model.lastReport)
                Divider()
                content
                Divider()
                footer
            }
        }
        .task { await model.rescan() }
        .sheet(item: $model.pendingConfirmation) { confirmation in
            ConfirmSheet(
                confirmation: confirmation,
                onConfirm: {
                    Task {
                        switch confirmation.kind {
                        case .cleanup: await model.confirmCleanup()
                        case .deleteMounts: await model.confirmDeleteMounts()
                        }
                    }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        }
        .alert("Ошибка", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if $0 == false { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var sectionBinding: Binding<AppModel.Section?> {
        Binding(get: { model.section }, set: { model.section = $0 ?? .xcode })
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .xcode: XcodeSectionView(model: model)
        case .arcadia: ArcadiaSectionView(model: model)
        case .log: LogView(lines: model.logLines)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await model.rescan() }
            } label: {
                Label("Пересканировать", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.isWorking)
            if model.isWorking {
                ProgressView().controlSize(.small)
                Text("Выполняется…").foregroundStyle(.secondary)
            }
            Spacer()
            Text("Выбрано: \(model.selectedItems.count)")
                .foregroundStyle(.secondary)
            Button("Очистить выбранное", role: .destructive) {
                model.requestCleanup()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(model.selectedItems.isEmpty || model.isWorking || model.isScanning)
        }
        .padding(12)
        .background(.bar)
    }
}
