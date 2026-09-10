import SwiftUI
import XcodeCleanerCore

/// A real checkbox column instead of table selection: picking three mounts out of ten should not
/// require knowing that shift-click extends a selection.
///
/// A `List` with a header built by hand rather than a `Table`, because a click anywhere on a row
/// has to tick that row's checkbox: a `Table` can only make its cells tappable, which leaves a dead
/// strip along every column boundary and along both edges of the row.
struct ArcadiaSectionView: View {
    @Bindable var model: AppModel

    /// Shared by the header and the rows, which is the only thing keeping the columns lined up now
    /// that `TableColumn` is not doing it.
    private enum Column {
        static let checkbox: CGFloat = 24
        static let status: CGFloat = 120
        static let lastUsed: CGFloat = 140
        static let size: CGFloat = 110
        static let spacing: CGFloat = 10
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(model.sortedMounts) { info in
                        row(info)
                    }
                } header: {
                    header
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
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

    private var header: some View {
        HStack(spacing: Column.spacing) {
            Color.clear.frame(width: Column.checkbox, height: 1)
            Text("Маунт")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Статус")
                .frame(width: Column.status, alignment: .leading)
            Text("Последний раз")
                .frame(width: Column.lastUsed, alignment: .leading)
            Text("Размер")
                .frame(width: Column.size, alignment: .leading)
        }
    }

    /// The whole row ticks the checkbox. The main mount stays inert because `setSelected` refuses
    /// it, so the rule lives in one place instead of being restated here.
    private func row(_ info: ArcMountInfo) -> some View {
        HStack(spacing: Column.spacing) {
            checkbox(info)
                .frame(width: Column.checkbox, alignment: .leading)

            HStack(spacing: 6) {
                Text(info.mount.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if info.isMain {
                    Text("основной")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(info.mount.mount)

            Text(info.mount.isMounted ? "смонтирован" : "размонтирован")
                .foregroundStyle(info.mount.isMounted ? Color.green : Color.secondary)
                .frame(width: Column.status, alignment: .leading)

            Text(RelativeDate.string(info.lastUsedAt))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Column.lastUsed, alignment: .leading)

            size(info)
                .frame(width: Column.size, alignment: .leading)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.setSelected(info, model.isSelected(info) == false) }
    }

    @ViewBuilder
    private func checkbox(_ info: ArcMountInfo) -> some View {
        if info.isMain {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text("Основной маунт удалить нельзя"))
                .help("Основной маунт удалить нельзя")
        } else {
            Toggle("", isOn: Binding(
                get: { model.isSelected(info) },
                set: { model.setSelected(info, $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(Text(info.mount.name))
        }
    }

    @ViewBuilder
    private func size(_ info: ArcMountInfo) -> some View {
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
