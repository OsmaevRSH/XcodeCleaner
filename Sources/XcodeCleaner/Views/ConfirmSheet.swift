import SwiftUI
import XcodeCleanerCore

struct ConfirmSheet: View {
    let confirmation: Confirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(confirmation.title)
                .font(.title2)
            List(confirmation.entries) { entry in
                HStack {
                    if entry.isDestructive {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help(confirmation.kind.destructiveHint)
                    }
                    Text(entry.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(entry.sizeBytes.map(ByteFormatting.string) ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 200)
            HStack {
                Text("Итого: \(ByteFormatting.string(confirmation.totalBytes))")
                    .font(.headline)
                Spacer()
            }
            if confirmation.shutsDownSimulators {
                Label("Запущенные симуляторы будут выключены", systemImage: "power")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if confirmation.hasDestructive {
                Toggle(confirmation.kind.acknowledgement, isOn: $acknowledged)
                    .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                // Return belongs to «Отмена»: this sheet opens with the destructive button ready,
                // and a stray Return should never be the thing that deletes.
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.defaultAction)
                Button("Удалить", role: .destructive, action: onConfirm)
                    .disabled(confirmation.hasDestructive && acknowledged == false)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onExitCommand(perform: onCancel)
    }
}
