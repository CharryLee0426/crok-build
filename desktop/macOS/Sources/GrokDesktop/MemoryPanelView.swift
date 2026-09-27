import AppKit
import SwiftUI

/// The Memory panel: notes grouped Global / Workspace / Sessions beside a preview of the selected note.
struct MemoryPanelView: View {
    @EnvironmentObject var extensions: ExtensionFeatureModel
    @ObservedObject var model: MemoryPanelModel
    let filter: String
    @State private var confirmDelete: MemoryFileItem?

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            statusBar.padding(.horizontal, 24).padding(.vertical, 12)
        }
        .onChange(of: filter) { _, value in if !value.isEmpty { model.loadSearchContents() } }
        .confirmationDialog(confirmDelete.map { "Delete \($0.label) from \($0.scopeLabel)?" } ?? "", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.forgetSelected(); confirmDelete = nil }
        } message: { Text("Dream may re-derive it from future sessions.") }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { model.listing?.enabled ?? false }, set: { _ in model.toggle() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory").font(.system(size: 13, weight: .semibold))
                    Text(stateText).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }
            .toggleStyle(.switch).controlSize(.small)
            .disabled(model.toggling || !(model.listing.map { $0.enabled || $0.canEnable } ?? false))
            .help(model.listing?.canEnable == false && model.listing?.enabled == false ? "Memory can't be turned on in this session." : "Turn memory on or off for this session")
            if model.toggling { ProgressView().controlSize(.small) }
            Spacer()
            Button { model.flush() } label: { Label("Flush", systemImage: "square.and.arrow.down.on.square") }
                .help("Save this task's completed turns to memory now")
                .disabled(model.listing?.enabled != true || model.busy != nil)
            Button { model.dream() } label: { Label("Dream", systemImage: "moon.stars") }
                .help("Organize saved notes into topics")
                .disabled(model.listing?.enabled != true || model.listing?.dreamEnabled != true || model.busy != nil)
        }.buttonStyle(SubtleButtonStyle()).font(.system(size: 12, weight: .medium))
    }

    private var stateText: String {
        guard let listing = model.listing else { return model.loading ? "Loading…" : "Unavailable" }
        if !listing.enabled { return "Off for this session" }
        let notes = listing.files.filter { !$0.generated }.count
        return "On · \(notes == 1 ? "1 note" : "\(notes) notes")" + (listing.captureEnabled ? " · saved after each turn" : "")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let listing = model.listing {
            if !listing.enabled {
                notice(title: MemoryDisabledExplanation.text(listing.disabledReason).title, detail: MemoryDisabledExplanation.text(listing.disabledReason).detail, symbol: "brain")
            } else if !listing.hasNotes {
                emptyNotice(listing)
            } else {
                HStack(spacing: 0) {
                    fileList(listing).frame(width: 350)
                    Divider()
                    previewPane
                }
            }
        } else if let error = model.error {
            notice(title: "Memory is unavailable", detail: error, symbol: "exclamationmark.triangle")
        } else {
            ProgressView("Loading memory…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notice(title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }.frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyNotice(_ listing: MemoryListing) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "brain").font(.system(size: 26)).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Text("Nothing remembered yet.").font(.system(size: 16, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MemoryDisabledExplanation.emptyState(captureEnabled: listing.captureEnabled, dreamEnabled: listing.dreamEnabled), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(Theme.muted); Text(line) }.font(.system(size: 13))
                }
            }
            Text("Crok Build remembers conventions, decisions, and project facts across sessions so you don't have to repeat yourself. Notes live in workspace memory for this repository and global memory shared across all your projects.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: 520, alignment: .leading).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileList(_ listing: MemoryListing) -> some View {
        let sections = listing.sections(matching: filter, contents: model.searchContents)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(sections, id: \.title) { section in
                    Text(section.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10).padding(.top, section.title == sections.first?.title ? 2 : 12).padding(.bottom, 4)
                    ForEach(section.files) { file in fileRow(file) }
                }
                if sections.isEmpty {
                    Text("No notes match “\(filter)”").font(.system(size: 13)).foregroundStyle(Theme.muted).padding(16)
                }
            }.padding(10)
        }
    }

    private func fileRow(_ file: MemoryFileItem) -> some View {
        let selected = model.selection == file.path
        return Button { model.select(file.path) } label: {
            HStack(spacing: 8) {
                Image(systemName: file.generated ? "list.bullet.rectangle" : file.source == "session" ? "clock" : "doc.text")
                    .font(.system(size: 12)).foregroundStyle(selected ? Theme.accent : Theme.muted).frame(width: 16).accessibilityHidden(true)
                Text(file.label).font(.system(size: 13, weight: selected ? .medium : .regular)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text("\(file.sizeText) · \(MemoryFileItem.age(file.modified))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.muted).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(selected ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .accessibilityLabel("\(file.label), \(file.source) memory")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Preview

    @ViewBuilder private var previewPane: some View {
        if let file = model.selectedFile {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.label).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text((file.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    if file.generated { ExtensionBadge(text: "Generated index") }
                    IconButton(icon: "doc.on.doc", help: "Copy path", size: 28) { model.copySelectedPath() }
                    IconButton(icon: "arrow.up.forward.app", help: "Open in editor", size: 28) { model.openSelected() }
                    IconButton(icon: "trash", help: file.isDeletable ? "Delete note" : "This file can't be deleted here", size: 28) {
                        if case .text = model.preview { confirmDelete = file } else { model.forgetSelected() }
                    }.disabled(!file.isDeletable || model.busy != nil).keyboardShortcut(.delete, modifiers: .command)
                }.padding(.horizontal, 18).padding(.vertical, 12)
                Divider()
                ScrollView {
                    Group {
                        switch model.preview {
                        case .text(let text, _)?: MarkdownContent(text: text, style: .panel)
                        case .tooLarge?: Text("File too large to preview").italic().foregroundStyle(Theme.muted)
                        case .unreadable?: Text("This file couldn't be read.").foregroundStyle(Theme.muted)
                        case nil: ProgressView().controlSize(.small)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
                }
            }
        } else {
            Text("Select a note to preview it.").font(.system(size: 13)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).foregroundStyle(Theme.muted)
            } else if let status = model.status {
                Image(systemName: status.isError ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(status.isError ? Color.red : Theme.green).accessibilityHidden(true)
                Text(status.text).foregroundStyle(status.isError ? Color.red : Theme.ink).lineLimit(2).textSelection(.enabled)
            } else if let listing = model.listing, listing.enabled, listing.hasNotes {
                Text("Notes are Markdown files on your Mac. Deleting one can't be undone.").foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }.font(.system(size: 12)).frame(minHeight: 18)
    }
}
