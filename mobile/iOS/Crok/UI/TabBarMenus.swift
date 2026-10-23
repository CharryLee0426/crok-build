import SwiftUI
import UIKit

/// Long-press menus on the system tab bar's items (Telegram: hold Chats for "Mark All as Read", hold Settings for the
/// accounts). SwiftUI's `TabView` has no such hook, so this installs one `UIContextMenuInteraction` on the
/// `UITabBar` of the tab bar controller it sits in and asks `menu` for the item under the finger. Put it in the
/// background of a tab's content.
struct TabBarContextMenus: UIViewControllerRepresentable {
    /// The menu for the tab at an index, or nil for none.
    let menu: @MainActor (Int) -> UIMenu?

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.menu = menu
        controller.install()
    }

    final class Controller: UIViewController, UIContextMenuInteractionDelegate {
        var menu: (@MainActor (Int) -> UIMenu?)?
        private weak var bar: UITabBar?
        private var interaction: UIContextMenuInteraction?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        func install() {
            guard let tabBar = tabBarController?.tabBar, bar !== tabBar else { return }
            if let interaction, let old = bar { old.removeInteraction(interaction) }
            let interaction = UIContextMenuInteraction(delegate: self)
            tabBar.addInteraction(interaction)
            self.interaction = interaction
            bar = tabBar
        }

        /// The tab bar's item views, left to right (private classes: `UITabBarButton`, `_UITabButton`…), or nil when
        /// they cannot be told apart from the rest of the bar.
        private func itemViews(in bar: UITabBar) -> [UIView]? {
            let count = bar.items?.count ?? 0
            guard count > 0 else { return nil }
            var found: [UIView] = []
            func walk(_ view: UIView) {
                for child in view.subviews where !child.isHidden && child.alpha > 0.01 {
                    let name = NSStringFromClass(type(of: child))
                    if name.contains("TabBarButton") || name.hasSuffix("TabButton") {
                        found.append(child)
                    } else {
                        walk(child)
                    }
                }
            }
            walk(bar)
            let sorted = found.sorted { $0.convert($0.bounds, to: bar).minX < $1.convert($1.bounds, to: bar).minX }
            return sorted.count == count ? sorted : nil
        }

        private func itemIndex(at location: CGPoint, in bar: UITabBar) -> Int? {
            let count = bar.items?.count ?? 0
            guard count > 0 else { return nil }
            if let views = itemViews(in: bar) {
                for (index, view) in views.enumerated() {
                    let frame = view.convert(view.bounds, to: bar).insetBy(dx: -6, dy: -8)
                    if frame.contains(location) { return index }
                }
                // Between items: the nearest one.
                let distances = views.map { abs($0.convert($0.bounds, to: bar).midX - location.x) }
                return distances.indices.min(by: { distances[$0] < distances[$1] })
            }
            let width = max(1, bar.bounds.width)
            return min(count - 1, max(0, Int(location.x / (width / CGFloat(count)))))
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            guard let bar, let index = itemIndex(at: location, in: bar), let menu = menu?(index) else { return nil }
            return UIContextMenuConfiguration(identifier: NSNumber(value: index), previewProvider: nil) { _ in menu }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
            highlightPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            preview(for: identifier)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction, configuration: UIContextMenuConfiguration,
            dismissalPreviewForItemWithIdentifier identifier: any NSCopying
        ) -> UITargetedPreview? {
            preview(for: identifier)
        }

        /// The pressed item lifts, not the whole bar.
        private func preview(for identifier: any NSCopying) -> UITargetedPreview? {
            guard let bar, let index = (identifier as? NSNumber)?.intValue, let views = itemViews(in: bar),
                views.indices.contains(index), views[index].window != nil
            else { return nil }
            let view = views[index]
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(
                roundedRect: view.bounds, cornerRadius: min(view.bounds.height, view.bounds.width) / 2)
            return UITargetedPreview(view: view, parameters: parameters)
        }
    }
}
