import SwiftUI
import XcodeCleanerCore

/// The search roots, in the one place a person without a terminal can reach them. A sheet rather
/// than a section in the sidebar: this is not something to browse, it is something to open, change
/// and close.
///
/// The editor is plain text, one root per line, because that is what the setting is — a short list
/// of paths, usually pasted. A table of rows with add and remove buttons would be more chrome than
/// the thing it edits.
struct SettingsSheet: View {
    let onSave: ([String]) -> Void
    let onCancel: () -> Void

    @State private var text: String

    init(roots: [String], onSave: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: roots.joined(separator: "\n"))
    }

    private var lines: [String] { text.components(separatedBy: .newlines) }

    var body: some View {
        let normalized = CachePaths.normalizedSearchRoots(lines)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Где искать проектные кэши")
                .font(.title2)
            Text(
                """
                Приложение ищет папки .build, Derived и DerivedData внутри этих папок в каждом \
                смонтированном маунте Arcadia. Пути задаются от корня маунта: mobile/saft/ios — \
                это ~/arcadia/mobile/saft/ios.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            editor

            feedback(normalized)

            HStack {
                Button("Сбросить") {
                    text = CachePaths.defaultProjectSearchRoots.joined(separator: "\n")
                }
                .help("Вернуть встроенные пути в поле")
                Spacer()
                Button("Отмена", role: .cancel, action: onCancel)
                Button("Сохранить") { onSave(lines) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand(perform: onCancel)
    }

    /// Keeps the editor's own background — that is the colour a text field has on this system — and
    /// only rounds and outlines it, so it reads as a field rather than as a hole in the sheet.
    private var editor: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .accessibilityLabel(Text("Корни проектов, по одному в строке"))
    }

    /// What the typed text amounts to right now, so the answer arrives while typing rather than
    /// after saving. An empty list is a valid answer and says so instead of reading as a mistake.
    @ViewBuilder
    private func feedback(
        _ normalized: (roots: [String], rejected: [(line: String, reason: String)])
    ) -> some View {
        if normalized.roots.isEmpty {
            Text(
                """
                Список пуст — поиск пойдёт по встроенным путям: \
                \(CachePaths.defaultProjectSearchRoots.joined(separator: ", ")).
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("\(RussianPlural.searchRoots(normalized.roots.count)) в списке")
                .foregroundStyle(.secondary)
        }
        if normalized.rejected.isEmpty == false {
            Text(
                normalized.rejected
                    .map { "«\($0.line.trimmingCharacters(in: .whitespaces))» — \($0.reason)" }
                    .joined(separator: "\n")
            )
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
