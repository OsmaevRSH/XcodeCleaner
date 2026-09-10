import SwiftUI
import XcodeCleanerCore

/// A real checkbox column instead of table selection: picking three mounts out of ten should not
/// require knowing that shift-click extends a selection.
struct ArcadiaSectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Table(model.sortedMounts) {
                TableColumn("") { info in
                    if info.isMain {
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                            .help("Основной маунт удалить нельзя")
                    } else {
                        Toggle("", isOn: Binding(
                            get: { model.isSelected(info) },
                            set: { model.setSelected(info, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                }
                .width(24)

                TableColumn("Маунт") { info in
                    HStack(spacing: 6) {
                        Text(info.mount.name)
                        if info.isMain {
                            Text("основной")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .help(info.mount.mount)
                }

                TableColumn("Статус") { info in
                    Text(info.mount.isMounted ? "смонтирован" : "размонтирован")
                        .foregroundStyle(info.mount.isMounted ? Color.green : Color.secondary)
                }
                .width(120)

                TableColumn("Последний раз") { info in
                    Text(RelativeDate.string(info.lastUsedAt))
                        .foregroundStyle(.secondary)
                }
                .width(140)

                TableColumn("Размер") { info in
                    if info.isMain {
                        Text("—")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if let bytes = model.size(of: info) {
                        Text(ByteFormatting.string(bytes))
                            .monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .width(110)
            }
            .scanningOverlay(model.isScanning)

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
                .background(Color.orange.opacity(0.15))
            }
        }
    }
}

@MainActor
private enum RelativeDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter
    }()

    static func string(_ date: Date?) -> String {
        guard let date else { return "—" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
