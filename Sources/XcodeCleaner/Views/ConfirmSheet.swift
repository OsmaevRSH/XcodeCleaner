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
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
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
            if confirmation.hasDestructive {
                Toggle(
                    "Понимаю, что отмеченные ⚠︎ данные не регенерируются и не восстанавливаются автоматически",
                    isOn: $acknowledged
                )
                .toggleStyle(.checkbox)
            }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Удалить", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(confirmation.hasDestructive && acknowledged == false)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
