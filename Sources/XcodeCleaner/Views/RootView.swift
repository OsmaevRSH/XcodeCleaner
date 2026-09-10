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
                DiskHeaderView(disk: model.scan.disk, bytesToFree: bytesToFree, freedBytes: freedBytes)
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
                        case .cleanup: await model.confirmXcodeCleanup()
                        case .deleteMounts: await model.confirmMountRemoval()
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

    /// Scoped to the section the user is looking at: an Xcode selection never inflates the Arcadia
    /// total, and the log answers for neither.
    private var bytesToFree: Int64? {
        switch model.section {
        case .xcode: model.selectedItems.isEmpty ? nil : model.xcodeBytesToFree
        case .arcadia: model.selectedMounts.isEmpty ? nil : model.arcadiaBytesToFree
        case .log: nil
        }
    }

    private var freedBytes: Int64? {
        guard model.showsLastResult, let freed = model.lastReport?.freedBytes else { return nil }
        // The figure is a delta between two `df` readings, and other processes write while a
        // cleanup runs, so it can come out negative. «Освободилось -1,2 ГБ» is not a report.
        return max(0, freed)
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .xcode: XcodeSectionView(model: model)
        case .arcadia: ArcadiaSectionView(model: model)
        case .log: LogView(model: model)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.rescan() }
            } label: {
                Label("Пересканировать", systemImage: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.isWorking)

            if model.isWorking {
                ProgressView().controlSize(.small)
                Text("Выполняется…").foregroundStyle(.secondary)
            } else if model.isMeasuring {
                ProgressView().controlSize(.small)
                Text("Считаю размеры…").foregroundStyle(.secondary)
            }

            Spacer()
            actions
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder
    private var actions: some View {
        switch model.section {
        case .xcode:
            Button("Очистить Xcode · \(ByteFormatting.string(model.xcodeBytesToFree))", role: .destructive) {
                model.requestXcodeCleanup()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(model.selectedItems.isEmpty || model.isWorking || model.isScanning)
        case .arcadia:
            Button("Размонтировать выбранные") {
                Task { await model.unmountSelected() }
            }
            .disabled(
                model.selectedMounts.contains { $0.mount.isMounted } == false
                    || model.isWorking
                    || model.isScanning
            )
            Button(
                "Удалить \(RussianPlural.mounts(model.selectedMounts.count)) · \(ByteFormatting.string(model.arcadiaBytesToFree))",
                role: .destructive
            ) {
                model.requestMountRemoval()
            }
            .disabled(model.selectedMounts.isEmpty || model.isWorking || model.isScanning)
        case .log:
            EmptyView()
        }
    }
}
