import AppKit
import Combine
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

/// A small filled circle for menus, where SwiftUI shapes do not render.
func colorDot(_ code: UInt32?, size: CGFloat = 10) -> Image {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        (code.map { NSColor(srgbRed: CGFloat(($0 >> 16) & 0xFF) / 255, green: CGFloat(($0 >> 8) & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
            ?? NSColor.gray).setFill()
        NSBezierPath(ovalIn: rect).fill()
        return true
    }
    image.isTemplate = false
    return Image(nsImage: image)
}

/// Fills the space it is given with an image, cropping the overflow. The transparent base decides the size, so a tall or wide
/// image can never push its neighbours (such as a card header) out of place.
struct FillImage: View {
    let image: NSImage
    var body: some View {
        Color.clear.overlay { Image(nsImage: image).resizable().scaledToFill() }.clipped()
    }
}

extension Color {
    /// Paste stores pinboard colors as ARGB integers.
    init(argb: UInt32) {
        self.init(.sRGB, red: Double((argb >> 16) & 0xFF) / 255, green: Double((argb >> 8) & 0xFF) / 255,
                  blue: Double(argb & 0xFF) / 255, opacity: 1)
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @FocusState private var searchFocused: Bool
    @State private var newBoardName = ""
    @State private var boardRenameText = ""

    var body: some View {
        VStack(spacing: 10) {
            header
            if model.cards.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 16) {
                            ForEach(Array(model.cards.enumerated()), id: \.element.id) { index, card in
                                CardView(card: card, number: index < 9 ? index + 1 : nil, selected: card.id == model.selection, model: model)
                                    .id(card.id)
                                    .onAppear { model.loadMoreIfNeeded(after: card) }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
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
        .shelfGlass(cornerRadius: 34)
        .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.38), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
        .overlay(alignment: .top) { resizeHandle }
        .shadow(color: .black.opacity(0.38), radius: 22, y: 8)
        .padding(ShelfController.pad)
        .preferredColorScheme(.dark)
        .onAppear { searchFocused = true }
    }

    /// Drag the top edge to make the shelf taller: past a threshold the cards switch to colored headers and big previews.
    private var resizeHandle: some View {
        Capsule().fill(Color.white.opacity(0.22)).frame(width: 40, height: 4).padding(.top, 5)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .top)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in model.onResizeDrag?() }
                .onEnded { _ in model.onResizeEnd?() })
    }

    private var header: some View {
        ZStack {
            chips.padding(.leading, (!model.query.isEmpty || model.hasFilters) ? 640 : 340).padding(.trailing, 340)
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
        .overlay(alignment: .topLeading) { suggestionList.padding(.leading, 112).offset(y: 38) }
        .zIndex(10)
    }

    @ViewBuilder private var suggestionList: some View {
        let items = model.suggestions
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { suggestion in
                    Button { model.apply(suggestion) } label: {
                        Label(suggestion.title, systemImage: suggestion.symbol)
                            .font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6).frame(width: 190)
            .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
        }
    }

    private var searchField: some View {
        let active = !model.query.isEmpty || model.hasFilters
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            filterMenu
            ForEach(model.kindFilters.sorted { $0.rawValue < $1.rawValue }, id: \.self) { kind in
                filterChip(kind.title, symbol: kind.symbol) { model.kindFilters.remove(kind) }
            }
            if let app = model.appFilter { filterChip(app, symbol: "app") { model.appFilter = nil } }
            if let preset = model.datePreset { filterChip(preset.rawValue, symbol: preset.symbol) { model.datePreset = nil } }
            TextField("", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .frame(width: active ? 150 : 2)
            if active {
                Text(model.statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { model.query = ""; model.clearFilters() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(active ? Color.white.opacity(0.10) : Color.clear, in: Capsule())
        .animation(.easeOut(duration: 0.15), value: active)
    }

    private func filterChip(_ title: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium))
            Text(title).font(.system(size: 12, weight: .medium))
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.white.opacity(0.16), in: Capsule())
    }

    private var filterMenu: some View {
        Menu {
            Menu("Type") {
                ForEach(ClipKind.allCases, id: \.self) { kind in
                    Toggle(isOn: Binding(get: { model.kindFilters.contains(kind) },
                                         set: { if $0 { model.kindFilters.insert(kind) } else { model.kindFilters.remove(kind) } })) {
                        Label(kind.title, systemImage: kind.symbol)
                    }
                }
            }
            Menu("App") {
                ForEach(model.appsInUse, id: \.bundleID) { app in Button(app.name) { model.appFilter = app.name } }
                Divider()
                Button("Any app") { model.appFilter = nil }
            }
            Menu("Date") {
                ForEach(DatePreset.allCases) { preset in Button(preset.rawValue) { model.datePreset = preset } }
                Divider()
                Button("Any time") { model.datePreset = nil }
            }
            Divider()
            Button("Clear Filters") { model.clearFilters() }.disabled(!model.hasFilters)
        } label: {
            Image(systemName: model.hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 13)).foregroundStyle(model.hasFilters ? Color.accentColor : Color.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .onTapGesture { model.refreshApps() }
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
                } else if board.id == ShelfModel.trashID {
                    Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                } else if board.id == ShelfModel.stackID {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 11, weight: .medium))
                } else {
                    Circle().fill(model.boardColors[board.id].map { Color(argb: $0) } ?? Color.gray).frame(width: 9, height: 9)
                }
                Text(board.id == ShelfModel.stackID ? "Paste Stack · \(model.stack.ids.count)" : board.name)
                    .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(selected ? Color.white.opacity(0.16) : Color.clear, in: Capsule())
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.72))
        }
        .buttonStyle(.plain)
        .contextMenu { boardMenu(board) }
        .popover(isPresented: Binding(get: { model.renamingBoardID == board.id }, set: { if !$0 { model.renamingBoardID = nil } })) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Rename pinboard").font(.headline)
                TextField("Name", text: $boardRenameText).frame(width: 200).onSubmit { model.renameBoard(board.id, to: boardRenameText) }
                HStack { Spacer(); Button("Save") { model.renameBoard(board.id, to: boardRenameText) }.keyboardShortcut(.defaultAction) }
            }.padding(14)
        }
    }

    @ViewBuilder private func boardMenu(_ board: BoardRecord) -> some View {
        if board.id == ShelfModel.stackID {
            Button("End Paste Stack") { model.toggleStack() }
        } else if board.id != ShelfModel.historyID, board.id != ShelfModel.trashID {
            Button("Rename…") { boardRenameText = board.name; model.renamingBoardID = board.id }
            Menu("Color") {
                ForEach(BoardPalette.colors, id: \.code) { color in
                    Button { model.recolorBoard(board.id, code: color.code) } label: {
                        Label { Text(color.name) } icon: { colorDot(color.code) }
                    }
                }
            }
            Divider()
            Button("Move Left") { model.moveBoard(board.id, by: -1) }
            Button("Move Right") { model.moveBoard(board.id, by: 1) }
            Divider()
            Button("Delete Pinboard", role: .destructive) { model.deleteBoard(board.id) }
        }
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
            if model.indexing {
                ProgressView(value: model.indexingProgress).frame(width: 220)
                Text("Indexing your library… \(Int(model.indexingProgress * 100))%").font(.system(size: 14, weight: .medium))
                Text("New copies are still being saved.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
            Image(systemName: "doc.on.clipboard").font(.system(size: 26)).foregroundStyle(.secondary)
            Text(model.query.isEmpty ? (model.inTrash ? "Trash is empty" : "Nothing here yet") : "No matches").font(.system(size: 14, weight: .medium))
            if !model.query.isEmpty { Text("Try fewer letters or another spelling.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
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

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 20, style: .continuous) }
    private static let headerShape = UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20, style: .continuous)

    var body: some View {
        Group { if model.expanded { expanded } else { compact } }
            .frame(width: model.cardWidth, height: model.cardHeight)
            .background(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.105)], startPoint: .top, endPoint: .bottom), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .overlay { if selected { shape.inset(by: -5).stroke(Color.accentColor, lineWidth: 3) } }   // ring sits outside, so corners stay clean
            .shadow(color: .black.opacity(selected ? 0.5 : 0.32), radius: selected ? 16 : 9, y: 5)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.selection = card.id; model.pasteSelected(plain: false) }
            .onTapGesture { model.selection = card.id }
            .onAppear { loadPreview() }
            .onReceive(model.$linkVersion.dropFirst()) { _ in loadPreview() }
            .contextMenu { menu }
            .popover(isPresented: Binding(get: { model.renamingID == card.id }, set: { if !$0 { model.renamingID = nil } })) { renamePopover }
            .background { Color.clear.popover(isPresented: Binding(get: { model.editingID == card.id }, set: { if !$0 { model.editingID = nil } })) { editPopover } }
    }

    private func loadPreview() {
        PreviewStore.shared.load(card.record) { loaded in
            preview = loaded
            if loaded.isLink, model.settings.linkPreviews { model.linkService?.request(loaded.text) }
        }
    }

    // MARK: compact

    private var compact: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                (Text(card.record.title ?? kindLabel).fontWeight(.semibold) + Text("  " + compactAge).foregroundColor(.secondary))
                    .font(.system(size: 11.5)).lineLimit(1)
                Spacer(minLength: 4)
                appIcon(17)
            }
            .padding(.horizontal, 11).padding(.top, 9).padding(.bottom, 6)
            content.padding(.horizontal, 11).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                Spacer()
                Image(systemName: bottomSymbol).font(.system(size: 9)).foregroundStyle(.secondary)
                if let number { Text("\(number)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
        }
    }

    // MARK: expanded

    private var headerColor: Color {
        PreviewStore.shared.appColor(bundleID: card.record.appBundleID) ?? {
            switch kindLabel { case "Link": return Color(red: 0.20, green: 0.45, blue: 0.95); case "Image": return Color(red: 0.90, green: 0.30, blue: 0.28)
            case "File": return Color(red: 0.30, green: 0.50, blue: 0.80); default: return Color(red: 0.93, green: 0.62, blue: 0.20) }
        }()
    }

    /// Type and spacing grow with the card so a big card never looks empty.
    private var scale: CGFloat { min(max(model.cardHeight / 250, 1), 1.5) }

    private var expanded: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.record.title ?? kindLabel).font(.system(size: 17 * min(scale, 1.2), weight: .semibold)).lineLimit(1)
                    Text((card.record.title == nil ? "" : kindLabel + " · ") + longAge).font(.system(size: 12 * min(scale, 1.2))).opacity(0.85).lineLimit(1)
                }
                Spacer(minLength: 4)
                appIcon(42).shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10).frame(height: 66)
            .background { Rectangle().fill(LinearGradient(colors: [headerColor.opacity(0.98), headerColor.opacity(0.84)], startPoint: .top, endPoint: .bottom)) }
            .overlay(alignment: .top) { LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom).frame(height: 22) }
            .clipShape(Self.headerShape)   // rounded only where it meets the card's corners; the bottom edge is straight

            expandedBody.frame(maxWidth: .infinity, maxHeight: .infinity)

            ZStack {
                Text(footer).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                HStack { Spacer(); if let number { Text("⌘\(number)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary) } }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var expandedBody: some View {
        let s = scale
        if let preview {
            if let image = preview.image {
                FillImage(image: image).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if let size = preview.imageSize {
                            Text("\(Int(size.width)) × \(Int(size.height))").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.45), in: Capsule()).padding(.bottom, 10)
                        }
                    }
            } else if !preview.fileNames.isEmpty {
                VStack(spacing: 10) {
                    Spacer(minLength: 0)
                    if let thumb = preview.fileImage { Image(nsImage: thumb).resizable().scaledToFit().frame(maxHeight: 130 * s).shadow(radius: 6, y: 3) }
                    Text(preview.fileNames.first ?? "").font(.system(size: 15 * s, weight: .semibold)).lineLimit(2).multilineTextAlignment(.center)
                    if let path = preview.filePaths.first {
                        Text(path).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 0)
                }.padding(14)
            } else if preview.isLink {
                VStack(spacing: 0) {
                    ZStack {
                        if let image = preview.linkImage {
                            FillImage(image: image).frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            LinearGradient(colors: [headerColor.opacity(0.38), headerColor.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
                            Image(systemName: "globe").font(.system(size: 54 * s, weight: .ultraLight)).foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(preview.linkTitle ?? linkHost(preview.text)).font(.system(size: 16 * s, weight: .semibold)).lineLimit(2)
                        HStack(spacing: 5) {
                            if let icon = preview.linkIcon { Image(nsImage: icon).resizable().frame(width: 12 * s, height: 12 * s).clipShape(RoundedRectangle(cornerRadius: 3)) }
                            Text(preview.linkTitle == nil ? preview.text : linkHost(preview.text)).font(.system(size: 11 * s)).foregroundStyle(.secondary).lineLimit(preview.linkTitle == nil ? 2 : 1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
            } else {
                let parts = preview.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
                let code = looksLikeCode(preview.text)
                VStack(alignment: .leading, spacing: 8 * s) {
                    if parts.count == 2, !code {
                        Text(parts[0]).font(.system(size: 17 * s, weight: .semibold))
                        Text(parts[1]).font(.system(size: 14.5 * s))
                    } else {
                        Text(preview.text.isEmpty ? "(no text)" : preview.text)
                            .font(.system(size: (code ? 13 : 16) * s, design: code ? .monospaced : .default))
                    }
                }
                .multilineTextAlignment(.leading).lineSpacing(2)
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: shared pieces

    @ViewBuilder private func appIcon(_ size: CGFloat) -> some View {
        if let icon = PreviewStore.shared.icon(bundleID: card.record.appBundleID) {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        }
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
                VStack(alignment: .leading, spacing: 6) {
                    if let image = preview.linkImage {
                        FillImage(image: image).frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Spacer(minLength: 0)
                        Image(systemName: "safari").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    }
                    Text(preview.linkTitle ?? linkHost(preview.text)).font(.system(size: 12, weight: .semibold)).lineLimit(preview.linkTitle == nil ? 1 : 2)
                    Text(preview.linkTitle == nil ? preview.text : linkHost(preview.text)).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            } else {
                Text(preview.text.isEmpty ? "(no text)" : preview.text)
                    .font(.system(size: 12, design: looksLikeCode(preview.text) ? .monospaced : .default))
                    .lineLimit(max(6, Int((model.cardHeight - 80) / 15))).multilineTextAlignment(.leading)
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

    private var footer: String {
        guard let preview else { return "" }
        if let size = preview.imageSize, preview.image != nil { return model.expanded ? "" : "\(Int(size.width)) × \(Int(size.height))" }
        if !preview.fileNames.isEmpty { return "\(preview.fileNames.count) file\(preview.fileNames.count == 1 ? "" : "s")" }
        if preview.isLink { return linkHost(preview.text) }
        return "\(preview.charCount) characters"
    }

    private var ageSeconds: Double { max(0, Date().timeIntervalSince1970 - card.record.copiedAt) }

    private var compactAge: String {
        switch ageSeconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(ageSeconds / 60))m"
        case ..<86_400: return "\(Int(ageSeconds / 3600))h"
        case ..<2_592_000: return "\(Int(ageSeconds / 86_400))d"
        default: return "\(Int(ageSeconds / 2_592_000))mo"
        }
    }

    private var longAge: String {
        if ageSeconds < 60 { return "just now" }
        return RelativeDateTimeFormatter.full.localizedString(for: Date(timeIntervalSince1970: card.record.copiedAt), relativeTo: Date())
    }

    private func linkHost(_ text: String) -> String { URL(string: text)?.host ?? text }
    private func looksLikeCode(_ text: String) -> Bool { text.contains("{") || text.contains("$ ") || text.contains("=>") || text.contains("();") || text.hasPrefix("#!") }

    // MARK: menus and popovers

    @ViewBuilder private var menu: some View {
        if model.inTrash {
            Button("Restore") { model.restore(card.id) }
        } else {
            Button("Paste") { model.selection = card.id; model.pasteSelected(plain: false) }
            Button("Paste as Plain Text") { model.selection = card.id; model.pasteSelected(plain: true) }
            Button("Copy") { model.copy(card.record) }
            Divider()
            if model.canEdit(card.record) { Button("Edit…") { model.beginEdit(card.id) } }
            Button("Rename…") { renameText = card.record.title ?? ""; model.renamingID = card.id }
            Menu("Pin to") {
                ForEach(model.boards.filter { $0.id != ShelfModel.historyID && $0.id != ShelfModel.trashID && $0.id != ShelfModel.stackID }, id: \.id) { board in
                    Button { model.pin(card.id, to: board) } label: {
                        Label { Text(board.name) } icon: { colorDot(model.boardColors[board.id]) }
                    }
                }
                Divider()
                Button("Create Pinboard…") { model.pendingPinClipID = card.id; model.addingBoard = true }
            }
            Divider()
            Button("Quick Look") { model.selection = card.id; model.quickLookID = card.id }
            if let preview {
                if let image = preview.image {
                    ShareLink(item: Image(nsImage: image), preview: SharePreview("Image", image: Image(nsImage: image)))
                } else if !preview.text.isEmpty {
                    ShareLink(item: preview.text)
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.delete(card.id) }
        }
    }

    private var editPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit text").font(.headline)
            TextEditor(text: $model.editText).font(.system(size: 12, design: .monospaced)).frame(width: 380, height: 240)
            HStack {
                Text("The original stays in your library.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.editingID = nil }
                Button("Save") { model.edit(card.id, text: model.editText) }.keyboardShortcut(.defaultAction)
            }
        }.padding(14)
    }

    private var renamePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name this clip").font(.headline)
            TextField("Title", text: $renameText).frame(width: 220).onSubmit { model.rename(card.id, to: renameText) }
            HStack { Spacer(); Button("Save") { model.rename(card.id, to: renameText) }.keyboardShortcut(.defaultAction) }
        }.padding(14)
    }
}

/// Space on a card: a larger look at the full content.
struct QuickLookView: View {
    let card: ShelfCard
    @ObservedObject var model: ShelfModel
    @State private var preview: Preview?
    @State private var fullText: String?
    @State private var fullImage: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.record.title ?? "Quick Look").font(.headline).lineLimit(1)
                Spacer()
                if let path = preview?.filePaths.first {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                if let preview, preview.isLink, let url = URL(string: preview.text) {
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
                Button("Copy") { model.copy(card.record) }
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16).frame(width: 580, height: 440)
        .shelfGlass(cornerRadius: 22)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 8)
        .padding(ShelfController.pad)
        .preferredColorScheme(.dark)
        .onAppear { PreviewStore.shared.load(card.record) { preview = $0 } }
        .task {
            let engine = model.engine, record = card.record
            let loaded = await Task.detached(priority: .userInitiated) { () -> (String, NSImage?) in
                let text = String(engine.text(of: record).prefix(200_000))
                return (text, engine.imageData(of: record).flatMap { NSImage(data: $0) })
            }.value
            fullText = loaded.0
            fullImage = loaded.1
        }
    }

    @ViewBuilder private var content: some View {
        if let image = fullImage {
            Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 8))
        } else if let preview, !preview.filePaths.isEmpty {
            VStack(spacing: 10) {
                if let thumb = preview.fileImage { Image(nsImage: thumb).resizable().scaledToFit().frame(maxHeight: 200) }
                ForEach(preview.filePaths, id: \.self) { Text($0).font(.system(size: 12)).textSelection(.enabled).lineLimit(2).truncationMode(.middle) }
            }
        } else if let text = fullText {
            ScrollView {
                Text(text).font(.system(size: 13, design: text.contains("{") || text.contains("$ ") ? .monospaced : .default))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ProgressView()
        }
    }
}

extension RelativeDateTimeFormatter {
    static let full: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
