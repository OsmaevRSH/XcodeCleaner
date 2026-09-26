import AppKit
import SwiftUI
import XcodeCleanerCore

/// Where project caches are looked for, in the one place a person without a terminal can reach it.
/// A sheet rather than a section in the sidebar: this is not something to browse, it is something
/// to open, change and close.
///
/// Two lists, edited two different ways because they are two different kinds of path. The Arcadia
/// roots are short paths relative to a mount, the same in every mount, usually pasted — so they are
/// plain text, one per line. The other folders are absolute paths to places on this disk, which
/// nobody should have to type — so they are picked in the standard folder panel and shown as rows
/// with a button to take each one out.
struct SettingsSheet: View {
    let home: URL
    let onSave: (_ roots: [String], _ folders: [String]) -> Void
    let onCancel: () -> Void

    @State private var text: String
    @State private var folders: [URL]
    /// What the last «Добавить папку…» refused, and why. Kept until the next pick, so the reason
    /// stays readable after the panel has closed.
    @State private var rejectedFolders: [(line: String, reason: String)] = []

    init(
        roots: [String],
        folders: [URL],
        home: URL,
        onSave: @escaping (_ roots: [String], _ folders: [String]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.home = home
        self.onSave = onSave
        self.onCancel = onCancel
        _text = State(initialValue: roots.joined(separator: "\n"))
        _folders = State(initialValue: folders)
    }

    private var lines: [String] { text.components(separatedBy: .newlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Где искать проектные кэши")
                .font(.title2)

            arcadiaSection

            foldersSection

            HStack {
                Spacer()
                Button("Отмена", role: .cancel, action: onCancel)
                Button("Сохранить") { onSave(lines, folders.map(\.path)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand(perform: onCancel)
    }

    // MARK: Arcadia

    private var arcadiaSection: some View {
        let normalized = CachePaths.normalizedSearchRoots(lines)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("В маунтах Arcadia")
                    .font(.headline)
                Spacer()
                Button("Сбросить") {
                    text = CachePaths.defaultProjectSearchRoots.joined(separator: "\n")
                }
                .help("Вернуть встроенные пути в поле")
            }
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

            rootsFeedback(normalized)
        }
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
    private func rootsFeedback(
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

    // MARK: Other folders

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Другие папки")
                    .font(.headline)
                Spacer()
                Button("Добавить папку…", action: addFolders)
            }

            folderList

            Text(
                """
                Приложение ищет папки .build рядом с Package.swift на глубину до восьми уровней и \
                не заходит на другие диски и в маунты Arcadia.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if rejectedFolders.isEmpty == false {
                Text(
                    rejectedFolders
                        .map { "«\($0.line)» — \($0.reason)" }
                        .joined(separator: "\n")
                )
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Outlined like the editor above it, so the two lists read as two fields of the same form.
    private var folderList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if folders.isEmpty {
                Text("Папки не выбраны")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(folders.enumerated()), id: \.element) { index, folder in
                    if index > 0 {
                        Divider()
                    }
                    folderRow(folder)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func folderRow(_ folder: URL) -> some View {
        HStack(spacing: 8) {
            Text(CachePaths.displayPath(folder, home: home))
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
            Spacer(minLength: 0)
            Button {
                folders.removeAll { $0 == folder }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text("Убрать папку"))
            .help("Убрать папку")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// The standard panel, folders only, several at once. What comes back goes through the same
    /// normalisation the saved list does, so a folder picked twice is listed once and a system
    /// root is refused here, in red, instead of being saved and ignored later.
    private func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Добавить"
        panel.directoryURL = home
        guard panel.runModal() == .OK else { return }
        let result = CachePaths.normalizedSearchFolders(
            folders.map(\.path) + panel.urls.map(\.path),
            home: home
        )
        folders = result.folders
        rejectedFolders = result.rejected
    }
}
