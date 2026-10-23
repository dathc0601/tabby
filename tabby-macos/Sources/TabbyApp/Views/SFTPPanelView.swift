#if canImport(AppKit)
import AppKit
import SwiftUI
import TabbyCore
import TabbySSHLib

/// The SFTP panel (Tabby's `SFTPPanelComponent`): breadcrumb (double-click to type a path),
/// Refresh, Filter, Create directory, Upload files / folder, close; the listing with Go up,
/// size, date and mode; drop files from Finder to upload; a context menu per entry.
struct SFTPPanelView: View {
    let controller: SFTPPanelController
    let close: () -> Void

    var body: some View {
        SFTPPanelContent(controller: controller, close: close).chromeEnvironment()
    }
}

private struct SFTPPanelContent: View {
    let controller: SFTPPanelController
    let close: () -> Void
    @Environment(\.chrome) private var chrome
    @Environment(\.metrics) private var metrics
    @State private var dropTargeted = false
    @FocusState private var filterFocused: Bool

    private var model: SFTPPanelModel { controller.model }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.showsFilter { filterBar }
            Rectangle().fill(chrome.separator.color).frame(height: 1)
            content
        }
        .foregroundStyle(chrome.text.color)
        .background(chrome.surfaceRaised.color)
        .overlay(alignment: .top) { Rectangle().fill(chrome.border.color).frame(height: 1) }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8).fill(chrome.accentFill.color)
                    .overlay(Label("Drop to upload to \(model.path)", systemImage: "folder").font(ChromeFont.headline))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            controller.upload(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onExitCommand { close() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            if model.isEditingPath {
                TextField("Path", text: Bindable(model).pathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.custom("Menlo", size: 12))
                    .onSubmit {
                        model.endEditingPath()
                        Task { await model.navigate(to: model.pathDraft) }
                    }
                    .onExitCommand { model.endEditingPath() }
            } else {
                breadcrumb
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { model.editPath() }
            }
            Spacer(minLength: 8)
            IconButton(symbol: "arrow.clockwise", help: "Refresh", size: 26) { Task { await model.refresh() } }
            IconButton(symbol: "line.3.horizontal.decrease", help: "Filter", isActive: model.showsFilter, size: 26) {
                model.showsFilter.toggle()
                if !model.showsFilter { model.filterText = "" } else { filterFocused = true }
            }
            IconButton(symbol: "folder.badge.plus", help: "Create directory", size: 26) { controller.createDirectory() }
            IconButton(symbol: "arrow.up.doc", help: "Upload files", size: 26) { controller.chooseFilesToUpload() }
            IconButton(symbol: "square.and.arrow.up.on.square", help: "Upload folder", size: 26) { controller.chooseFolderToUpload() }
            IconButton(symbol: "xmark", help: "Close", size: 26, action: close)
        }
        .padding(.horizontal, 10)
        .frame(height: CGFloat(metrics.tabBar))
    }

    private var breadcrumb: some View {
        HStack(spacing: 2) {
            Button { Task { await model.navigate(to: "/") } } label: { Text("SFTP").font(ChromeFont.body.weight(.bold)) }
                .buttonStyle(.plain)
            ForEach(Array(model.breadcrumb.enumerated()), id: \.offset) { _, crumb in
                Text("/").foregroundStyle(chrome.textFaint.color)
                Button { Task { await model.navigate(to: crumb.path) } } label: { Text(crumb.name).lineLimit(1) }
                    .buttonStyle(.plain)
            }
        }
        .font(ChromeFont.body)
    }

    private var filterBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(chrome.textMuted.color)
            TextField("Filter…", text: Bindable(model).filterText)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onExitCommand {
                    model.filterText = ""
                    model.showsFilter = false
                }
            if !model.filterText.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: "Clear", size: 22) { model.filterText = "" }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    // MARK: Listing

    @ViewBuilder
    private var content: some View {
        if let error = model.error {
            Text(error).font(ChromeFont.callout).foregroundStyle(chrome.danger.color)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 6)
        }
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.isLoading && model.entries.isEmpty {
                    status("Loading")
                }
                if model.canGoUp {
                    row(icon: "arrow.turn.left.up", name: "Go up", size: "", date: "", mode: "") { Task { await model.goUp() } }
                }
                if let empty = model.emptyMessage {
                    status(empty)
                }
                ForEach(model.entries, id: \.path) { entry in
                    row(icon: Self.icon(entry), name: entry.name, size: entry.isDirectory ? "" : Self.size(entry.size),
                        date: entry.modified.formatted(date: .abbreviated, time: .shortened), mode: SFTPEntry.modeString(entry.mode)) {
                        controller.activate(entry)
                    }
                    .contextMenu { menu(entry) }
                }
            }
        }
    }

    private func status(_ text: String) -> some View {
        Text(text).font(ChromeFont.callout).foregroundStyle(chrome.textMuted.color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).frame(height: CGFloat(metrics.selectorRow))
    }

    private func row(icon: String, name: String, size: String, date: String, mode: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(chrome.accent.color)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(size).foregroundStyle(chrome.textMuted.color).frame(width: 80, alignment: .trailing)
                Text(date).foregroundStyle(chrome.textMuted.color).frame(width: 150, alignment: .trailing)
                Text(mode).font(.custom("Menlo", size: 12)).foregroundStyle(chrome.textMuted.color).frame(width: 110, alignment: .trailing)
            }
            .font(ChromeFont.body)
            .padding(.horizontal, 12)
            .frame(height: CGFloat(metrics.selectorRow))
            .contentShape(Rectangle())
        }
        .buttonStyle(SFTPRowStyle(chrome: chrome))
    }

    @ViewBuilder
    private func menu(_ entry: SFTPEntry) -> some View {
        Button("Copy full path") { controller.copyPath(entry) }
        if !entry.isDirectory {
            Button("Edit locally") { controller.editLocally(entry) }
        }
        Button("Create directory") { controller.createDirectory() }
        Divider()
        if entry.isDirectory {
            Button("Download directory") { controller.downloadDirectory(entry) }
        } else {
            Button("Download") { controller.download(entry) }
        }
        Divider()
        Button("Delete", role: .destructive) { controller.delete(entry) }
    }

    static func icon(_ entry: SFTPEntry) -> String {
        if entry.isDirectory { return "folder" }
        if entry.isSymlink { return "arrow.triangle.turn.up.right.diamond" }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "gz", "tgz", "bz2", "xz", "tar", "7z", "rar": return "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic": return "photo"
        case "sh", "py", "js", "ts", "rb", "go", "rs", "swift", "c", "h", "php", "java", "json", "yaml", "yml", "toml", "conf", "ini":
            return "chevron.left.forwardslash.chevron.right"
        case "log", "txt", "md": return "doc.text"
        default: return "doc"
        }
    }

    static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

private struct SFTPRowStyle: ButtonStyle {
    let chrome: ChromeTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? chrome.fillStrong.color : Color.clear)
    }
}
#endif
