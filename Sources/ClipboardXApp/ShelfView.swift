import AppKit
import ClipboardXKit
import SwiftUI

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    /// Liquid Glass on macOS 26 and later, classic vibrancy before that.
    @ViewBuilder func shelfGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(VisualEffect()).clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

extension Color {
    /// Paste stores pinboard colors as ARGB integers.
    init(argb: UInt32) {
        self.init(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255, opacity: 1)
    }
}

private enum BoardPopover: Identifiable {
    case rename(String)
    case color(String)

    var id: String {
        switch self {
        case .rename(let boardID): "rename:\(boardID)"
        case .color(let boardID): "color:\(boardID)"
        }
    }

    var boardID: String {
        switch self {
        case .rename(let boardID), .color(let boardID): boardID
        }
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @FocusState private var searchFocused: Bool
    @State private var newBoardName = ""
    @State private var boardName = ""
    @State private var boardColor = Color.gray
    @State private var boardPopover: BoardPopover?
    @State private var deletingBoard: BoardRecord?

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.cards.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                                CardView(card: card, number: index < 9 ? index + 1 : nil, selected: card.id == model.selection, model: model)
                                    .id(card.id)
                                    .onAppear { model.loadMoreIfNeeded(after: card) }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 6)
                    }
                    .onChange(of: model.selection) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 10)
        .shelfGlass(cornerRadius: 30)
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
        .confirmationDialog("Delete Pinboard?", isPresented: Binding(
            get: { deletingBoard != nil },
            set: { if !$0 { deletingBoard = nil } }
        ), titleVisibility: .visible) {
            Button("Delete \(deletingBoard?.name ?? "")", role: .destructive) {
                if let deletingBoard { model.deleteBoard(deletingBoard.id) }
                deletingBoard = nil
            }
            Button("Cancel", role: .cancel) { deletingBoard = nil }
        } message: {
            Text("Its clips will return to Clipboard History.")
        }
    }

    private var header: some View {
        ZStack {
            chips.padding(.horizontal, 340)
            HStack(spacing: 8) {
                Text("ClipboardX").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.18), in: Capsule())
                searchField
                Spacer(minLength: 0)
                Button { newBoardName = ""; model.addingBoard = true } label: { Image(systemName: "plus").font(.system(size: 14, weight: .medium)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("New pinboard")
                    .popover(isPresented: $model.addingBoard) { newBoardPopover }
                Menu {
                    Button("Settings…") { model.onOpenSettings?() }
                } label: { Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 26).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            TextField("", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .frame(width: model.query.isEmpty ? 2 : 190)
            if !model.query.isEmpty {
                Text(model.statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(model.query.isEmpty ? Color.clear : Color.white.opacity(0.10), in: Capsule())
        .animation(.easeOut(duration: 0.15), value: model.query.isEmpty)
    }

    /// Centered when they fit; scrolls (and fades at the edges) on very narrow screens.
    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                ForEach(Array(model.boards.enumerated()), id: \.element.id) { index, board in chip(board, index: index) }
            }
            .frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(model.boards.enumerated()), id: \.element.id) { index, board in chip(board, index: index) }
                }
            }
        }
    }

    private func chip(_ board: BoardRecord, index: Int) -> some View {
        let selected = index == model.boardIndex
        return Button { model.selectBoard(index) } label: {
            HStack(spacing: 6) {
                if board.id == ShelfModel.historyID {
                    Image(systemName: "clock").font(.system(size: 11, weight: .medium))
                } else {
                    Circle().fill(model.boardColors[board.id].map { Color(argb: $0) } ?? Color.gray).frame(width: 9, height: 9)
                }
                Text(board.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.16) : Color.clear, in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename…") {
                boardName = board.name
                boardPopover = .rename(board.id)
            }
            Button("Change Color…") {
                boardColor = model.boardColors[board.id].map(Color.init(argb:)) ?? .gray
                boardPopover = .color(board.id)
            }
            Divider()
            Button("Move Left") { model.moveBoard(board.id, by: -1) }.disabled(index <= 1)
            Button("Move Right") { model.moveBoard(board.id, by: 1) }.disabled(index >= model.boards.count - 1)
            Divider()
            Button("Delete Pinboard…", role: .destructive) { deletingBoard = board }
        }
        .popover(item: Binding(
            get: { boardPopover?.boardID == board.id ? boardPopover : nil },
            set: { boardPopover = $0 }
        )) { popover in
            boardPopoverContent(popover)
        }
    }

    @ViewBuilder private func boardPopoverContent(_ popover: BoardPopover) -> some View {
        switch popover {
        case .rename(let id):
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename Pinboard").font(.headline)
                TextField("Name", text: $boardName).frame(width: 220)
                    .onSubmit { model.renameBoard(id, to: boardName); boardPopover = nil }
                HStack {
                    Button("Cancel") { boardPopover = nil }
                    Spacer()
                    Button("Save") { model.renameBoard(id, to: boardName); boardPopover = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(14)
        case .color(let id):
            VStack(alignment: .leading, spacing: 12) {
                Text("Pinboard Color").font(.headline)
                ColorPicker("Color", selection: $boardColor, supportsOpacity: false)
                HStack {
                    Button("Cancel") { boardPopover = nil }
                    Spacer()
                    Button("Save") {
                        if let code = Self.argbCode(for: boardColor) { model.setBoardColor(id, to: code) }
                        boardPopover = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(14).frame(width: 240)
        }
    }

    private static func argbCode(for color: Color) -> UInt32? {
        guard let color = NSColor(color).usingColorSpace(.deviceRGB) else { return nil }
        let alpha = UInt32((color.alphaComponent * 255).rounded())
        let red = UInt32((color.redComponent * 255).rounded())
        let green = UInt32((color.greenComponent * 255).rounded())
        let blue = UInt32((color.blueComponent * 255).rounded())
        return alpha << 24 | red << 16 | green << 8 | blue
    }

    private var newBoardPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New pinboard").font(.headline)
            TextField("Name", text: $newBoardName).frame(width: 200).onSubmit { model.addBoard(named: newBoardName) }
            HStack { Spacer(); Button("Create") { model.addBoard(named: newBoardName) }.keyboardShortcut(.defaultAction) }
        }.padding(14)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(model.query.isEmpty ? "Nothing here yet" : "No matches").font(.system(size: 14, weight: .medium))
            if !model.query.isEmpty { Text("Try fewer letters or another spelling.").font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .frame(width: 320, height: 190)
    }
}

struct CardView: View {
    let card: ShelfCard
    let number: Int?
    let selected: Bool
    @ObservedObject var model: ShelfModel
    @State private var preview: Preview?
    @State private var renameText = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                top
                content.padding(.horizontal, 11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                bottom
            }
        }
        .frame(width: 198, height: 198)
        .background(Color(white: 0.10).opacity(0.92), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.white.opacity(0.09), lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selection = card.id; model.pasteSelected(plain: false) }
        .onTapGesture { model.selection = card.id }
        .onAppear { PreviewStore.shared.load(card.record) { preview = $0 } }
        .contextMenu { menu }
        .popover(isPresented: Binding(get: { model.renamingID == card.id }, set: { if !$0 { model.renamingID = nil } })) { renamePopover }
    }

    private var top: some View {
        HStack(spacing: 6) {
            (Text(card.record.title ?? kindLabel).fontWeight(.semibold) + Text("  " + compactAge).foregroundColor(.secondary))
                .font(.system(size: 11.5)).lineLimit(1)
            Spacer(minLength: 4)
            if let icon = PreviewStore.shared.icon(bundleID: card.record.appBundleID) {
                Image(nsImage: icon).resizable().frame(width: 17, height: 17)
            }
        }
        .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 6)
    }

    private var bottom: some View {
        HStack(spacing: 4) {
            Spacer()
            Image(systemName: bottomSymbol).font(.system(size: 9)).foregroundStyle(.secondary)
            if let number { Text("\(number)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
    }

    @ViewBuilder private var content: some View {
        if let preview {
            if let image = preview.image {
                Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !preview.fileNames.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text(preview.fileNames.prefix(4).joined(separator: "\n")).font(.system(size: 12))
                }
            } else if preview.isLink {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Image(systemName: "safari").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(linkHost(preview.text)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(preview.text).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                Text(preview.text.isEmpty ? "(no text)" : preview.text)
                    .font(.system(size: 12, design: looksLikeCode(preview.text) ? .monospaced : .default))
                    .lineLimit(9).multilineTextAlignment(.leading)
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var kindLabel: String {
        if card.record.representations.contains(where: { $0.uti == "public.file-url" }) { return "File" }
        if preview?.image != nil { return "Image" }
        if preview?.isLink == true { return "Link" }
        return "Text"
    }

    private var bottomSymbol: String {
        switch kindLabel { case "Image": return "photo"; case "File": return "doc"; case "Link": return "link"; default: return "text.alignleft" }
    }

    private var compactAge: String {
        let seconds = max(0, Date().timeIntervalSince1970 - card.record.copiedAt)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        case ..<2_592_000: return "\(Int(seconds / 86_400))d"
        default: return "\(Int(seconds / 2_592_000))mo"
        }
    }

    private func linkHost(_ text: String) -> String { URL(string: text)?.host ?? text }
    private func looksLikeCode(_ text: String) -> Bool { text.contains("{") || text.contains("$ ") || text.contains("=>") || text.contains("();") || text.hasPrefix("#!") }

    @ViewBuilder private var menu: some View {
        Button("Paste") { model.selection = card.id; model.pasteSelected(plain: false) }
        Button("Paste as Plain Text") { model.selection = card.id; model.pasteSelected(plain: true) }
        Divider()
        Button("Rename…") { renameText = card.record.title ?? ""; model.renamingID = card.id }
        Menu("Pin to") {
            ForEach(model.boards.filter { $0.id != ShelfModel.historyID }, id: \.id) { board in
                Button(board.name) { model.pin(card.id, to: board) }
            }
        }
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name this clip").font(.headline)
            TextField("Title", text: $renameText).frame(width: 220).onSubmit { model.rename(card.id, to: renameText) }
            HStack { Spacer(); Button("Save") { model.rename(card.id, to: renameText) }.keyboardShortcut(.defaultAction) }
        }.padding(14)
    }
}
