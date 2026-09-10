import SwiftUI

struct LogView: View {
    let model: AppModel

    /// Whether new lines pull the view down with them. A cleanup streams output for a minute, and
    /// scrolling up to read something is pointless if the next line yanks the view back.
    @State private var follows = true
    @State private var isAtBottom = true
    /// Set while the scroll is the user's doing, so growing content never turns following off.
    @State private var isUserScrolling = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.logEntries) { entry in
                        Text(entry.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .id(entry.id)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - Self.bottomTolerance
            } action: { _, atBottom in
                isAtBottom = atBottom
                if isUserScrolling {
                    follows = atBottom
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .tracking || phase == .interacting || phase == .decelerating {
                    isUserScrolling = true
                    follows = isAtBottom
                } else if phase == .idle {
                    if isUserScrolling {
                        follows = isAtBottom
                    }
                    isUserScrolling = false
                }
            }
            .onChange(of: model.logEntries.last?.id) { _, id in
                guard follows, let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .overlay(alignment: .bottomTrailing) {
                if follows == false {
                    Button {
                        follows = true
                        if let id = model.logEntries.last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    } label: {
                        Label("К последним строкам", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(12)
                }
            }
        }
    }

    /// A line of monospaced text is taller than this, so a view resting at the bottom stays "at the
    /// bottom" through the rounding a scroll view does on its own.
    private static let bottomTolerance: CGFloat = 4
}
