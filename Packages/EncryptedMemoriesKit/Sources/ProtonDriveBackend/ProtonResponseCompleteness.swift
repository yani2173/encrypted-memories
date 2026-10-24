import Foundation

/// Only reviewed envelope fields can prove absence. An extra field can signal a partial response.
func protonResponseContainsOnly(_ fields: Set<String>, decoder: any Decoder) throws -> Bool {
    let keys = try decoder.container(keyedBy: ProtonResponseField.self).allKeys
    return Set(keys.map(\.stringValue)).isSubset(of: fields)
}

private struct ProtonResponseField: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
