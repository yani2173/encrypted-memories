import Foundation

public struct MLPipelineID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let nativeSearch = MLPipelineID(rawValue: "nativeSearch")
    public static let people = MLPipelineID(rawValue: "people")
    public static let pets = MLPipelineID(rawValue: "pets")
}

public struct MLStageID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum MLModelRole: String, Codable, Hashable, Sendable {
    case dualEncoder
    case imageEncoder
    case textEncoder
    case regionDetector
    case regionEmbedder
    case classifier
    case textRecognizer
    case featurePrinter
    case qualityAnalyzer
    case maskGenerator
}
