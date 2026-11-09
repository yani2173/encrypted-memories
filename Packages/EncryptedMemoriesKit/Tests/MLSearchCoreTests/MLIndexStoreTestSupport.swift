import PhotosCore

@testable import MLSearchCore

/// Whole-epoch reads for tests. They go through the production `forEachVectorBlock` and
/// `indexedUIDs` paths, so a test observes what the search engine and the planner observe.
extension MLIndexStore {
    /// The complete epoch as one block. A failing read returns the rows delivered before it.
    func vectorBlock(for descriptor: MLModelDescriptor) -> MLVectorBlock {
        var whole = MLVectorBlock(descriptor: descriptor)
        try? forEachVectorBlock(for: descriptor, maximumRows: max(count(for: descriptor), 1)) { block in
            for row in 0..<block.count {
                whole.append(uid: block.uids[row], vector: block.vector(at: row))
            }
        }
        return whole
    }

    func contains(uid: PhotoUID, descriptor: MLModelDescriptor) throws -> Bool {
        try indexedUIDs(for: descriptor, from: [uid]).contains(uid)
    }
}

extension InMemoryMLIndexStore {
    func contains(uid: PhotoUID, descriptor: MLModelDescriptor) -> Bool {
        indexedUIDs(for: descriptor, from: [uid]).contains(uid)
    }
}

extension MLVectorBlock {
    func vector(at row: Int) -> ContiguousArray<Float32> {
        withUnsafeStorage { ContiguousArray($0[(row * dimension)..<((row + 1) * dimension)]) }
    }

    var vectors: [ContiguousArray<Float32>] { (0..<count).map(vector(at:)) }
}
