import Foundation

extension Sequence where Element: Hashable {
    /// The elements without repeats, each at its first position.
    public func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
