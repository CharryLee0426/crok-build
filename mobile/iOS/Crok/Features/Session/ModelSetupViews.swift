import SwiftUI

/// The setup row above the composer's input row (mobile/DESIGN.md "Model and thinking level"): the model pill and,
/// for a model with thinking levels, the thinking pill, left-aligned. Not accent-filled: the Menu pill is the accent
/// one.
struct ModelSetupBar: View {
    let row: ModelSetupRow
    /// A new session: the thinking menu starts with Default.
    let offersDefault: Bool
    let onModel: () -> Void
    let onLevel: (String?) -> Void

    var body: some View {
        SetupRowLayout(spacing: 8) {
            Button(action: onModel) {
                SetupPillLabel(pill: row.model, symbol: "cpu")
            }
            .buttonStyle(.plain)
            .allowsHitTesting(row.acceptsModelTaps)
            .accessibilityLabel(Text("Model"))
            .accessibilityValue(Text(verbatim: Self.spoken(row.model)))
            .accessibilityIdentifier("modelPill")
            if let thinking = row.thinking, let levels = row.levelModel?.efforts {
                ThinkingMenu(levels: levels, current: row.levelId, offersDefault: offersDefault, onPick: onLevel) {
                    SetupPillLabel(pill: thinking, symbol: "brain")
                }
                .allowsHitTesting(row.acceptsLevelTaps)
                .accessibilityLabel(Text("Thinking level"))
                .accessibilityValue(Text(verbatim: Self.spoken(thinking)))
                .accessibilityIdentifier("thinkingPill")
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: row)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("modelSetupRow")
    }

    /// The pill's choice, and whether a change is on its way (the spinner).
    static func spoken(_ pill: SetupPill) -> String {
        pill.busy ? "\(pill.label), \(String(localized: "Sending"))" : pill.label
    }
}

/// A pill: a glyph, the choice's name (truncated in the middle), and a chevron, or a spinner while a change is on its
/// way. 30 pt high, on Liquid Glass (iOS 26) or a tinted capsule over the composer's material bar (earlier).
struct SetupPillLabel: View {
    let pill: SetupPill
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(pill.dimmed ? Color(uiColor: .tertiaryLabel) : Theme.accent)
                .accessibilityHidden(true)
            Text(verbatim: pill.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(pill.dimmed ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            ZStack {
                if pill.busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                        .accessibilityLabel(Text("Sending"))
                } else {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(pill.dimmed ? Color(uiColor: .tertiaryLabel) : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 12, height: 12)
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: 30)
        .modifier(PillSurface())
        .contentShape(Capsule())
    }

    /// iOS 26: glass, like the field beside it, floating over the transcript and its theme. Earlier: the bar is an
    /// opaque material whatever the theme, so the pills take the plain service tint (a theme's dark service capsules
    /// are made for the wallpaper, not for the bar).
    private struct PillSurface: ViewModifier {
        func body(content: Content) -> some View {
            if hasLiquidGlass {
                content.glassSurface(in: Capsule(), interactive: true)
            } else {
                content
                    .background(SessionPalette.standard.serviceBackground, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline))
            }
        }
    }
}

/// The two pills side by side: the model pill takes what it needs up to about 60 % of the row (more when the thinking
/// pill is short), the thinking pill the rest; both truncate rather than wrap.
struct SetupRowLayout: Layout {
    var spacing: CGFloat = 8
    /// The model pill's share of the row when the two compete.
    var modelShare: CGFloat = 0.6

    private func widths(for width: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard let width, width.isFinite else { return ideal }
        guard ideal.count == 2 else { return ideal.map { min($0, width) } }
        let room = max(0, width - spacing)
        let model = min(ideal[0], max(room * modelShare, room - ideal[1]))
        return [model, min(ideal[1], max(0, room - model))]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        let used = widths.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(for: bounds.width, subviews)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }
}

/// The thinking level menu, anchored to its pill or row: the system `Menu` with an inline `Picker` (a checkmark on the
/// current level), the model's levels in their order with their descriptions; a new session's starts with Default.
struct ThinkingMenu<Label: View>: View {
    let levels: [EffortChoice]
    /// The current level's option id; nil for Default (or a level the list does not have).
    let current: String?
    let offersDefault: Bool
    let onPick: (String?) -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            Picker(selection: Binding(get: { current.map(Choice.level) ?? .standard }, set: { onPick($0.levelId) })) {
                if offersDefault {
                    Text("Default").tag(Choice.standard)
                }
                ForEach(levels) { level in
                    if let description = level.description, !description.isEmpty {
                        // Two texts: the menu shows the second as the item's subtitle.
                        VStack(alignment: .leading) {
                            Text(verbatim: level.name)
                            Text(verbatim: description)
                        }
                        .tag(Choice.level(level.id))
                    } else {
                        Text(verbatim: level.name).tag(Choice.level(level.id))
                    }
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
        } label: {
            label()
        }
        .menuOrder(.fixed)
    }

    /// A picker tag: Default, or a level's option id.
    enum Choice: Hashable {
        case standard
        case level(String)

        var levelId: String? {
            if case .level(let id) = self { return id }
            return nil
        }
    }
}

/// Choose a Model: the computer's models by provider, searchable, the current one checked. A new session starts with
/// Default ("<computer>'s own choice"); an open session's list ends with a note that a change applies to the next
/// message.
struct ModelPickerSheet: View {
    let models: [ModelChoice]
    let computerName: String
    /// The current model's id; nil for Default.
    let current: String?
    /// A new session: Default first, and no note about the next message.
    let offersDefault: Bool
    let onPick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let sections = ModelCatalog.sections(models, computerName: computerName, query: query)
        let showsDefault = offersDefault && !searching
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if showsDefault {
                        Section {
                            defaultRow
                        }
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.models) { model in
                                row(model)
                                    .id(model.id)
                            }
                        } header: {
                            Text(verbatim: section.title)
                                .accessibilityIdentifier("modelSection-\(section.id)")
                        } footer: {
                            if !offersDefault, section.id == sections.last?.id {
                                Text("Model changes apply to your next message.")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .overlay {
                    if sections.isEmpty && !showsDefault {
                        ContentUnavailableView("No Results", systemImage: "magnifyingglass")
                            .accessibilityIdentifier("modelNoResults")
                    }
                }
                .onAppear {
                    // A long list opens on the current model.
                    if let current, models.count > 8 { proxy.scrollTo(current, anchor: .center) }
                }
            }
            .searchable(
                text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search models or providers"))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Choose a Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("modelPickerCancel")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("modelPicker")
    }

    private var defaultRow: some View {
        Button {
            pick(nil)
        } label: {
            rowLabel(
                title: String(localized: "Default"), subtitle: String(localized: "\(computerName)'s own choice"),
                monospacedSubtitle: false, description: nil, isCurrent: current == nil)
        }
        .accessibilityAddTraits(current == nil ? .isSelected : [])
        .accessibilityIdentifier("modelRow-default")
    }

    private func row(_ model: ModelChoice) -> some View {
        Button {
            pick(model.id)
        } label: {
            rowLabel(
                title: model.name, subtitle: model.id == model.name ? nil : model.id, monospacedSubtitle: true,
                description: model.description, isCurrent: model.id == current)
        }
        .accessibilityAddTraits(model.id == current ? .isSelected : [])
        .accessibilityIdentifier("modelRow-\(model.id)")
    }

    private func pick(_ id: String?) {
        dismiss()
        onPick(id)
    }

    private func rowLabel(
        title: String, subtitle: String?, monospacedSubtitle: Bool, description: String?, isCurrent: Bool
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(Color.primary)
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(monospacedSubtitle ? .caption.monospaced() : .caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
