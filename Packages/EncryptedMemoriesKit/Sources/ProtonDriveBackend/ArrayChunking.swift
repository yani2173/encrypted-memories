extension Array {
    /// Consecutive slices of at most `size` elements, in order. `size` must be positive.
    func chunked(by size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
