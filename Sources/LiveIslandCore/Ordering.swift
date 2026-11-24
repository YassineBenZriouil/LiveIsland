import Foundation

/// An order the user picked (the island's tabs), kept valid as the app changes: names it no
/// longer knows are dropped, repeats ignored, and anything new joins at the end.
public enum Ordering {
    /// The saved names in order, then the items they didn't mention, in their default order.
    public static func restore<Item>(_ saved: [String], all: [Item], name: (Item) -> String) -> [Item] {
        var result: [Item] = []
        var seen = Set<String>()
        for key in saved where !seen.contains(key) {
            guard let item = all.first(where: { name($0) == key }) else { continue }
            result.append(item)
            seen.insert(key)
        }
        result += all.filter { !seen.contains(name($0)) }
        return result
    }

    /// The items with the one at `index` moved `offset` places (−1 earlier, +1 later), stopping
    /// at either end.
    public static func move<Item>(_ items: [Item], from index: Int, by offset: Int) -> [Item] {
        guard items.indices.contains(index) else { return items }
        let target = min(max(index + offset, 0), items.count - 1)
        guard target != index else { return items }
        var moved = items
        moved.insert(moved.remove(at: index), at: target)
        return moved
    }

    /// The items the person didn't hide, in order. Never none: with every one hidden the first
    /// comes back, so the open island always has a page to show.
    public static func shown<Item>(_ items: [Item], hidden: Set<String>, name: (Item) -> String) -> [Item] {
        let shown = items.filter { !hidden.contains(name($0)) }
        return shown.isEmpty ? Array(items.prefix(1)) : shown
    }

    /// `wanted` when it's shown, else the first item that is: a hidden tab is never opened,
    /// even by an agent that needs you or a link.
    public static func pick<Item: Equatable>(_ wanted: Item, in shown: [Item]) -> Item? {
        shown.contains(wanted) ? wanted : shown.first
    }
}
