import SwiftUI
import QuickLook
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Browses the JARVIS folder: preview, share, rename, delete, import.
struct WorkspaceBrowserView: View {
    let folder: URL
    var onAskAbout: ((URL) -> Void)?

    @ObservedObject private var chat = ChatViewModel.shared
    @State private var items: [Workspace.Item] = []
    @State private var previewURL: URL?
    @State private var renameTarget: Workspace.Item?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var showImporter = false
    @State private var deleteTarget: Workspace.Item?
    @AppStorage("jarvis.filesGrid") private var gridMode = false

    private var workspace: Workspace { Workspace.shared }
    private var isRoot: Bool { folder.standardizedFileURL == workspace.root.standardizedFileURL }

    var body: some View {
        Group {
            if gridMode { grid } else { list }
        }
        .navigationTitle(isRoot ? "JARVIS Files" : folder.lastPathComponent)
        .toolbar { toolbar }
        .quickLookPreview($previewURL, in: items.filter { !$0.isDirectory }.map(\.url))
        .onAppear(perform: reload)
        .onReceive(chat.$recentFiles) { _ in reload() }
        .refreshable { reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                let destination = workspace.uniqueURL(for: folder.appendingPathComponent(url.lastPathComponent))
                try? FileManager.default.copyItem(at: url, to: destination)
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
            reload()
        }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let name = newFolderName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    try? FileManager.default.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
                }
                newFolderName = ""
                reload()
            }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .confirmationDialog(
            "Delete \(deleteTarget?.name ?? "")?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = deleteTarget {
                    #if os(macOS)
                    try? FileManager.default.trashItem(at: target.url, resultingItemURL: nil)
                    #else
                    try? FileManager.default.removeItem(at: target.url)
                    #endif
                }
                deleteTarget = nil
                reload()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.largeTitle).foregroundColor(Theme.accent)
            Text("Nothing here yet").font(.headline)
            Text("Ask JARVIS to make something and it will appear here.")
                .font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var grid: some View {
        ScrollView {
            if items.isEmpty { emptyState }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 14) {
                ForEach(items) { item in
                    Group {
                        if item.isDirectory {
                            NavigationLink(value: item.url) { tile(item) }
                        } else {
                            Button { previewURL = item.url } label: { tile(item) }
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu { menu(for: item) }
                }
            }
            .padding(12)
        }
    }

    private func tile(_ item: Workspace.Item) -> some View {
        VStack(spacing: 6) {
            Group {
                if item.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.panel)
                } else {
                    FileThumbnail(url: item.url, maxPixel: 300)
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(item.name)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 104)
        }
    }

    private var list: some View {
        List {
            if items.isEmpty {
                emptyState.listRowBackground(Color.clear)
            }
            ForEach(items) { item in
                Group {
                    if item.isDirectory {
                        NavigationLink(value: item.url) { row(item) }
                    } else {
                        Button { previewURL = item.url } label: { row(item) }
                            .buttonStyle(.plain)
                    }
                }
                .contextMenu { menu(for: item) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleteTarget = item } label: { Label("Delete", systemImage: "trash") }
                }
            }
        }
    }

    private func row(_ item: Workspace.Item) -> some View {
        HStack(spacing: 12) {
            Group {
                if item.isDirectory {
                    Image(systemName: "folder.fill")
                        .font(.title2)
                        .foregroundColor(Theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    FileThumbnail(url: item.url, maxPixel: 140)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body).lineLimit(1)
                HStack(spacing: 6) {
                    if !item.isDirectory {
                        Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    }
                    Text(item.modified, style: .relative)
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func menu(for item: Workspace.Item) -> some View {
        ShareLink(item: item.url) { Label("Share", systemImage: "square.and.arrow.up") }
        if let onAskAbout, !item.isDirectory {
            Button { onAskAbout(item.url) } label: { Label("Ask JARVIS about this", systemImage: "sparkles") }
        }
        Button {
            renameText = item.name
            renameTarget = item
        } label: { Label("Rename", systemImage: "pencil") }
        Button {
            let copy = workspace.uniqueURL(for: item.url)
            try? FileManager.default.copyItem(at: item.url, to: copy)
            reload()
        } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        #if os(macOS)
        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: { Label("Show in Finder", systemImage: "folder") }
        Button { NSWorkspace.shared.open(item.url) } label: { Label("Open", systemImage: "arrow.up.forward.app") }
        #else
        if item.isImage {
            Button {
                Task { _ = try? await PhotoLibrary.save(imageAt: item.url) }
            } label: { Label("Save to Photos", systemImage: "photo.badge.plus") }
        }
        #endif
        Button(role: .destructive) { deleteTarget = item } label: { Label("Delete", systemImage: "trash") }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { gridMode.toggle() } label: {
                    Label(gridMode ? "Show as list" : "Show as gallery", systemImage: gridMode ? "list.bullet" : "square.grid.2x2")
                }
                Button { showNewFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                Button { showImporter = true } label: { Label("Import files", systemImage: "square.and.arrow.down") }
                #if os(iOS)
                Button {
                    // Opens this folder in the Files app.
                    if let url = URL(string: "shareddocuments://" + folder.path) { UIApplication.shared.open(url) }
                } label: { Label("Open in Files app", systemImage: "folder") }
                #else
                Button { NSWorkspace.shared.open(folder) } label: { Label("Open in Finder", systemImage: "folder") }
                #endif
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func reload() {
        items = workspace.items(in: folder)
    }

    private func rename() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTarget = nil
        guard !name.isEmpty, name != target.name, !name.contains("/") else { return }
        let destination = workspace.uniqueURL(for: target.url.deletingLastPathComponent().appendingPathComponent(name))
        try? FileManager.default.moveItem(at: target.url, to: destination)
        reload()
    }
}
