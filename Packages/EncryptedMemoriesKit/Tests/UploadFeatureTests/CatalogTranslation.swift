import Foundation
import PhotosCore
import XCTest

/// The translation of a package catalog key in one language. Xcode compiles the String Catalog to `.lproj` bundles;
/// a plain SwiftPM build copies the catalog file instead, so the file is read when no `.lproj` exists.
func catalogTranslation(of key: String, language: String) throws -> String? {
    let bundle = L10n.resourceBundle
    if let path = bundle.path(forResource: language, ofType: "lproj"), let localized = Bundle(path: path) {
        return localized.localizedString(forKey: key, value: nil, table: nil)
    }
    let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: "xcstrings"))
    let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let strings = catalog["strings"] as? [String: Any]
    let entry = strings?[key] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any]
    let localization = localizations?[language] as? [String: Any]
    return (localization?["stringUnit"] as? [String: Any])?["value"] as? String
}
