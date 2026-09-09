import SwiftUI
import XcodeCleanerCore

struct DiskHeaderView: View {
    let disk: DiskSpace?
    let bytesToFree: Int64
    let lastReport: CleanupReport?

    var body: some View {
        HStack(spacing: 24) {
            metric("Свободно", disk.map { ByteFormatting.string($0.available) })
            metric("Занято", disk.map { ByteFormatting.string($0.used) })
            metric("Всего", disk.map { ByteFormatting.string($0.total) })
            Divider().frame(height: 32)
            metric("Освободится", ByteFormatting.string(bytesToFree), highlighted: bytesToFree > 0)
            if let freed = lastReport?.freedBytes {
                Divider().frame(height: 32)
                metric("Последняя очистка", ByteFormatting.string(freed))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func metric(_ title: String, _ value: String?, highlighted: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(.title3.monospacedDigit())
                .fontWeight(highlighted ? .semibold : .regular)
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
        }
    }
}
