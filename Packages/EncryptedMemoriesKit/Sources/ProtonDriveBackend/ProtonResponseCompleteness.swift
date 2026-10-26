import Foundation

/// Field names that tell a client that an answer is partial or has a next page. No marker is verified for the
/// `links/fetch_metadata` endpoint, so this list is a defensive judgment. A marker makes an answer incomplete by its
/// presence, whatever its value. Compared without case. At the top level a marker is an unknown field anyway.
private let protonPartialResponseMarkers: Set<String> = [
    "more", "truncated", "incomplete", "partial", "nextpage", "nextanchor", "anchorid", "cursor", "continuation",
]

/// The top-level fields of a `links/fetch_metadata` answer that are known: Proton's own client reads `Parents` next to
/// `Code` and `Links`. Compared with the exact spelling.
private let protonKnownMetadataEnvelopeFields: Set<String> = ["Code", "Links", "Parents"]

/// What the shape of a `links/fetch_metadata` answer says about its completeness.
struct ProtonMetadataEnvelope: Equatable {
    /// False when a marker of a partial answer appears, or when the shape is not the known one.
    let isComplete: Bool
    /// True when a top-level field outside the known ones appears, or when `Parents` is not an array of objects. The
    /// caller counts it, so an answer that is incomplete for this reason does not switch off the report unseen.
    let isUnsupported: Bool
}

/// Reads the shape of a `links/fetch_metadata` answer without interpreting any value:
/// - a top-level field other than `Code`, `Links` and `Parents` makes it unsupported and incomplete, and so does a
///   key that only differs in case from one of them; a marker name at the top level is such a field;
/// - `Parents` has to be an array of objects, otherwise it is unsupported and incomplete;
/// - a marker name as a key of an object in `Links` or `Parents` makes it incomplete.
func protonMetadataEnvelope(decoder: any Decoder) throws -> ProtonMetadataEnvelope {
    let container = try decoder.container(keyedBy: ProtonResponseField.self)
    var isComplete = true
    var isUnsupported = container.allKeys.contains { !protonKnownMetadataEnvelopeFields.contains($0.stringValue) }
    for name in ["Links", "Parents"] {
        let field = ProtonResponseField(name)
        guard container.contains(field) else { continue }
        switch objectsCarryMarker(in: container, key: field) {
        case true?: isComplete = false
        case false?: break
        case nil:
            // A `Links` value that is no array of objects fails the decoding of the answer before this point.
            isUnsupported = true
        }
    }
    return ProtonMetadataEnvelope(isComplete: isComplete && !isUnsupported, isUnsupported: isUnsupported)
}

/// Whether any object of the array under `key` has a marker name as a key. Nil when the value is no array of objects.
private func objectsCarryMarker(
    in container: KeyedDecodingContainer<ProtonResponseField>, key: ProtonResponseField
) -> Bool? {
    guard var objects = try? container.nestedUnkeyedContainer(forKey: key) else { return nil }
    var carriesMarker = false
    while !objects.isAtEnd {
        guard let object = try? objects.nestedContainer(keyedBy: ProtonResponseField.self) else { return nil }
        if object.allKeys.contains(where: { protonPartialResponseMarkers.contains($0.stringValue.lowercased()) }) {
            carriesMarker = true
        }
    }
    return carriesMarker
}

private struct ProtonResponseField: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
