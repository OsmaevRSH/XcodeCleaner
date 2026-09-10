import SwiftUI
import XcodeCleanerCore

struct ArcadiaSectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Размонтировать выбранные") {
                    Task { await model.unmountSelected() }
                }
                .disabled(model.selectedMounts.contains { $0.mount.isMounted } == false || model.isWorking)
                Button("Удалить выбранные", role: .destructive) {
                    model.requestDeleteMounts()
                }
                .disabled(model.selectedMounts.isEmpty || model.isWorking)
            }
            .padding(12)

            Table(model.scan.mounts, selection: $model.selectedMountIDs) {
                TableColumn("Маунт") { info in
                    HStack(spacing: 6) {
                        if info.isMain {
                            Image(systemName: "lock.fill").foregroundStyle(.secondary)
                        }
                        Text(info.mount.name)
                    }
                    .help(info.mount.mount)
                }
                TableColumn("Статус") { info in
                    Text(info.mount.isMounted ? "mounted" : "unmounted")
                        .foregroundStyle(info.mount.isMounted ? Color.green : Color.secondary)
                }
                .width(90)
                TableColumn("Store") { info in
                    Text(info.storeSizeBytes.map(ByteFormatting.string) ?? "—")
                        .monospacedDigit()
                }
                .width(100)
                TableColumn("Object store") { info in
                    Text(info.sharesMainObjectStore ? "общий" : "свой")
                        .foregroundStyle(.secondary)
                }
                .width(90)
            }

            if let retryPath = model.unmountRetryPath {
                HStack {
                    Text("arc отказался размонтировать \(retryPath)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Повторить с --force") {
                        Task { await model.retryUnmountWithForce() }
                    }
                }
                .padding(12)
                .background(Color.yellow.opacity(0.15))
            }
        }
    }
}
