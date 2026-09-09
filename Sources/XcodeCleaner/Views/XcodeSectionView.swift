import SwiftUI
import XcodeCleanerCore

struct XcodeSectionView: View {
    @Bindable var model: AppModel

    var body: some View {
        List {
            ForEach(CleanupKind.executionOrder) { kind in
                Section {
                    controls(for: kind)
                    let group = model.items(for: kind)
                    if group.isEmpty {
                        Text("Нечего чистить")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(group) { item in
                        row(item)
                    }
                } header: {
                    header(for: kind)
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if model.isScanning {
                ProgressView("Сканирование…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func header(for kind: CleanupKind) -> some View {
        HStack {
            Toggle(kind.title, isOn: Binding(
                get: { model.isGroupSelected(kind) },
                set: { model.setSelected(kind: kind, $0) }
            ))
            .toggleStyle(.checkbox)
            .font(.headline)
            Spacer()
            Text(ByteFormatting.string(model.items(for: kind).reduce(0) { $0 + ($1.sizeBytes ?? 0) }))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func controls(for kind: CleanupKind) -> some View {
        switch kind {
        case .simulators:
            Picker("Режим", selection: $model.simulatorMode) {
                ForEach(SimulatorMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
        case .archives:
            Stepper("Старше \(model.archiveMaxAgeDays) дней", value: $model.archiveMaxAgeDays, in: 0...365, step: 5)
        default:
            EmptyView()
        }
    }

    private func row(_ item: CleanupItem) -> some View {
        HStack {
            Toggle(isOn: Binding(
                get: { model.isSelected(item) },
                set: { _ in model.toggle(item) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                        if item.isDestructive {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Данные не регенерируются")
                        }
                    }
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Text(item.sizeBytes.map(ByteFormatting.string) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
