import SwiftUI

/// A sidebar list whose tasks the user can put in order.
enum SidebarTaskList: Hashable {
    case project(UUID)
    case pinned
}

/// Drag to reorder, as in Codex's sidebar: the row lifts and follows the pointer, the rows it
/// passes slide aside to open a gap, and on release it settles into the gap. Releasing it well
/// away from the list puts it back. The drag starts from whatever the row applies its handle
/// to, so a folder moves by its header while its tasks move on their own. VoiceOver users get
/// Move Up and Move Down actions instead.
struct ReorderableStack<Item: Identifiable, Row: View>: View where Item.ID == UUID {
    let items: [Item]
    let spacing: CGFloat
    /// Moves an item so it ends at this index of `items`.
    let onMove: (UUID, Int) -> Void
    let row: (Item, ReorderHandle) -> Row

    @State private var frames: [UUID: CGRect] = [:]
    /// Changes animate: the rows that make way slide.
    @State private var drag: ReorderDrag?
    /// Follows the pointer without animation, so the lifted row never lags it.
    @State private var translation: CGFloat = 0
    @State private var space = UUID()

    /// `preview` starts the list mid-drag, for snapshots.
    init(items: [Item], spacing: CGFloat = 1, onMove: @escaping (UUID, Int) -> Void,
         preview: (drag: ReorderDrag, translation: CGFloat)? = nil, @ViewBuilder row: @escaping (Item, ReorderHandle) -> Row) {
        self.items = items
        self.spacing = spacing
        self.onMove = onMove
        self.row = row
        _drag = State(initialValue: preview?.drag)
        _translation = State(initialValue: preview?.translation ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                let lifted = drag?.id == item.id
                row(item, handle(for: item.id, at: index))
                    .background {
                        if lifted {
                            // Opaque, so the rows it passes do not show through.
                            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.canvas)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover.opacity(0.7)))
                                .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
                        }
                    }
                    .scaleEffect(lifted ? 1.02 : 1, anchor: .center)
                    .offset(y: ReorderLayout.offset(of: index, drag: drag, translation: translation))
                    .zIndex(lifted ? 1 : 0)
                    // Outside the offset and scale, this is where the row rests, which is what a
                    // drag measures against.
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frames[item.id] = $0 }
            }
        }
        .coordinateSpace(.named(space))
    }

    private func handle(for id: UUID, at index: Int) -> ReorderHandle {
        ReorderHandle(
            space: space,
            onChanged: { value in changed(id, value) },
            onEnded: { value in ended(id, value) },
            moveUp: index > 0 ? { onMove(id, index - 1) } : nil,
            moveDown: index < items.count - 1 ? { onMove(id, index + 1) } : nil)
    }

    private func changed(_ id: UUID, _ value: DragGesture.Value) {
        guard let origin = items.firstIndex(where: { $0.id == id }), let frame = frames[id] else { return }
        if drag?.id != id {
            translation = 0
            withAnimation(.snappy(duration: 0.16)) { drag = ReorderDrag(id: id, origin: origin, target: origin, gap: frame.height + spacing) }
            NSCursor.closedHand.set()
        }
        guard var current = drag else { return }
        let bounds = ReorderLayout.bounds(items.compactMap { frames[$0.id] })
        // The row stays within the list, give or take a little overshoot.
        translation = min(max(value.translation.height, bounds.minY - frame.minY - 6), bounds.maxY - frame.maxY + 6)
        current.origin = origin
        current.target = ReorderLayout.target(pointerY: value.location.y, origin: origin, gap: current.gap,
                                              frames: items.map { frames[$0.id] ?? .zero })
        if current != drag { withAnimation(.snappy(duration: 0.2)) { drag = current } }
    }

    private func ended(_ id: UUID, _ value: DragGesture.Value) {
        NSCursor.arrow.set()
        guard let current = drag, current.id == id else { return }
        let bounds = ReorderLayout.bounds(items.compactMap { frames[$0.id] })
        // Letting go well outside the list is a change of mind.
        let cancelled = !bounds.insetBy(dx: -80, dy: -60).contains(value.location)
        withAnimation(.snappy(duration: 0.24)) {
            if !cancelled, current.target != current.origin { onMove(id, current.target) }
            drag = nil
            translation = 0
        }
    }
}

/// The row being dragged: where it started and the slot it would drop into.
struct ReorderDrag: Equatable {
    var id: UUID
    var origin: Int
    var target: Int
    /// The dragged row's height plus the list spacing: how far the rows it passes move aside.
    var gap: CGFloat
}

/// The arithmetic of a drag, kept apart from the view so tests can check it.
enum ReorderLayout {
    /// The slot a row dragged from `origin` drops into with the pointer at `pointerY`: one past
    /// every other row whose middle the pointer has passed. Rows below the origin are measured
    /// as if the dragged row had already left, so a tall folder swaps halfway, like a short row.
    static func target(pointerY: CGFloat, origin: Int, gap: CGFloat, frames: [CGRect]) -> Int {
        var target = 0
        for (index, frame) in frames.enumerated() where index != origin {
            let middle = index > origin ? frame.midY - gap : frame.midY
            if pointerY > middle { target += 1 }
        }
        return target
    }

    /// How far the row at `index` is drawn from its place while a drag is under way.
    static func offset(of index: Int, drag: ReorderDrag?, translation: CGFloat) -> CGFloat {
        guard let drag else { return 0 }
        if index == drag.origin { return translation }
        if drag.target > drag.origin, index > drag.origin, index <= drag.target { return -drag.gap }
        if drag.target < drag.origin, index >= drag.target, index < drag.origin { return drag.gap }
        return 0
    }

    static func bounds(_ frames: [CGRect]) -> CGRect {
        frames.dropFirst().reduce(frames.first ?? .zero) { $0.union($1) }
    }
}

/// What a row applies to the part the user grabs to drag it: its header, or the whole row.
struct ReorderHandle: ViewModifier {
    let space: UUID
    let onChanged: (DragGesture.Value) -> Void
    let onEnded: (DragGesture.Value) -> Void
    let moveUp: (() -> Void)?
    let moveDown: (() -> Void)?

    func body(content: Content) -> some View {
        content
            // High priority, so a drag does not also click the row once it lets go; a click that
            // never moves six points still reaches the row's buttons.
            .highPriorityGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
                    .onChanged(onChanged)
                    .onEnded(onEnded))
            .accessibilityActions {
                if let moveUp { Button("Move up", action: moveUp) }
                if let moveDown { Button("Move down", action: moveDown) }
            }
    }
}
