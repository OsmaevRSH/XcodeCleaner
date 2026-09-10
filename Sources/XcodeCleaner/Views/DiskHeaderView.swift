import SwiftUI
import XcodeCleanerCore

struct DiskHeaderView: View {
    let disk: DiskSpace?
    /// The total the current section would free, or nil when nothing is selected in it.
    let bytesToFree: Int64?
    /// What the last cleanup actually freed; takes the place of `bytesToFree` until the selection
    /// changes.
    let freedBytes: Int64?

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: usedFraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 420)
                Text(spaceLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let freedBytes {
                total("Освободилось", ByteFormatting.string(freedBytes))
            } else if let bytesToFree {
                total("Освободится", ByteFormatting.string(bytesToFree))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var usedFraction: Double {
        guard let disk, disk.total > 0 else { return 0 }
        return min(1, max(0, Double(disk.used) / Double(disk.total)))
    }

    private var spaceLine: String {
        guard let disk else { return "Место на диске неизвестно" }
        return "Свободно \(ByteFormatting.string(disk.available)) из \(ByteFormatting.string(disk.total))"
    }

    private func total(_ caption: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(Color.accentColor)
        }
    }
}
