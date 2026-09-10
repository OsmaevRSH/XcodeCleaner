import SwiftUI
import XcodeCleanerCore

/// One row per category, never one per path: the paths are what made the old list unreadable, so
/// they live in the expanded area and in tooltips.
struct XcodeSectionView: View {
    @Bindable var model: AppModel

    private static let groups: [CleanupGroup] = [.safe, .attention]

    var body: some View {
        List {
            ForEach(Self.groups) { group in
                let kinds = model.kinds(in: group)
                if kinds.isEmpty == false {
                    Section(group.title) {
                        ForEach(kinds) { kind in
                            category(kind)
                            if model.isExpanded(kind) {
                                controls(for: kind)
                                ForEach(model.items(for: kind)) { item in
                                    row(item)
                                }
                            }
                        }
                    }
                }
            }
            if model.items.isEmpty, model.isScanning == false {
                Text("Нечего чистить")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scanningOverlay(model.isScanning)
    }

    private func category(_ kind: CleanupKind) -> some View {
        HStack(spacing: 10) {
            categoryCheckbox(kind)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(for: kind))
                    if kind.group == .attention {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Не восстановится автоматически")
                    }
                }
                Text(subtitle(for: kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            categorySize(kind)

            Button {
                model.toggleExpanded(kind)
            } label: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(model.isExpanded(kind) ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
            .help(model.isExpanded(kind) ? "Свернуть" : "Показать, что внутри")
        }
        .padding(.vertical, 2)
    }

    /// A checkbox with all three states a category can be in. `Toggle` has two, so a category with
    /// part of it picked would look exactly like one with nothing picked.
    private func categoryCheckbox(_ kind: CleanupKind) -> some View {
        let state = model.selectionState(of: kind)
        return Button {
            model.toggleGroupSelection(kind)
        } label: {
            Image(systemName: Self.checkboxSymbol(selected: state.selected, total: state.total))
                .imageScale(.large)
                .foregroundStyle(state.selected == 0 ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title(for: kind)))
        .accessibilityValue(Text("Выбрано \(state.selected) из \(state.total)"))
        .help("Выбрано \(state.selected) из \(state.total)")
    }

    private static func checkboxSymbol(selected: Int, total: Int) -> String {
        if selected == 0 || total == 0 {
            return "square"
        }
        return selected == total ? "checkmark.square.fill" : "minus.square.fill"
    }

    private func categorySize(_ kind: CleanupKind) -> some View {
        HStack(spacing: 6) {
            Text(ByteFormatting.string(model.knownBytes(for: kind)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if model.hasPendingSizes(for: kind) {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func controls(for kind: CleanupKind) -> some View {
        switch kind {
        case .simulators:
            Picker("Что сделать с симуляторами", selection: $model.simulatorMode) {
                ForEach(SimulatorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .padding(.leading, 24)
        case .archives:
            Stepper(
                "Старше \(RussianPlural.daysAfterOlderThan(model.archiveMaxAgeDays))",
                value: $model.archiveMaxAgeDays,
                in: 0...365,
                step: 5
            )
            .padding(.leading, 24)
        case .xcodeCaches, .previews, .deviceSupport, .simulatorCaches, .xcodeApps, .toolchains,
             .projectCaches:
            EmptyView()
        }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack(spacing: 10) {
            Toggle(item.title, isOn: Binding(
                get: { model.isSelected(item) },
                set: { _ in model.toggle(item) }
            ))
            .toggleStyle(.checkbox)
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 12)
            if let bytes = model.size(of: item) {
                Text(ByteFormatting.string(bytes))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.leading, 24)
        .help(item.subtitle)
    }

    private func title(for kind: CleanupKind) -> String {
        switch kind {
        case .archives:
            "\(kind.title) старше \(RussianPlural.daysAfterOlderThan(model.archiveMaxAgeDays))"
        case .xcodeCaches, .previews, .deviceSupport, .simulatorCaches, .simulators, .xcodeApps,
             .toolchains, .projectCaches:
            kind.title
        }
    }

    private func subtitle(for kind: CleanupKind) -> String {
        switch kind {
        case .simulators:
            "\(model.simulatorMode.title) · \(RussianPlural.devices(model.scan.simulators?.devices.count ?? 0))"
        case .xcodeCaches, .previews, .deviceSupport, .simulatorCaches, .archives, .xcodeApps,
             .toolchains, .projectCaches:
            kind.subtitle
        }
    }
}
