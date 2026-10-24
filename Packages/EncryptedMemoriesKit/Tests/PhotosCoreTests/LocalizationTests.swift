import XCTest

@testable import PhotosCore

/// The catalog-content checks parse the `.xcstrings` JSON directly from the source tree (located via
/// `#filePath`), so they are deterministic regardless of the host's language - they validate the
/// *translations that ship*, not whatever language the test process happens to run in. The runtime
/// checks additionally prove the package bundle advertises both languages and falls back to English.
final class LocalizationTests: XCTestCase {
    private var repoRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }
    private var appCatalog: URL { repoRoot.appendingPathComponent("App/Localizable.xcstrings") }
    private var mobileCatalog: URL { repoRoot.appendingPathComponent("iOSApp/Localizable.xcstrings") }
    private var packageCatalog: URL {
        repoRoot.appendingPathComponent(
            "Packages/EncryptedMemoriesKit/Sources/PhotosCore/Resources/Localizable.xcstrings")
    }

    private struct Catalog {
        let sourceLanguage: String
        /// key to set of languages that have a non-empty value.
        let coverage: [String: Set<String>]
    }

    /// True if a localization node ("en"/"de" value) carries at least one non-empty string - either a
    /// direct `stringUnit` or any `variations` leaf (plurals/device/width).
    private func hasNonEmptyValue(_ node: Any) -> Bool {
        guard let dict = node as? [String: Any] else { return false }
        if let unit = dict["stringUnit"] as? [String: Any],
            let value = unit["value"] as? String, !value.isEmpty
        {
            return true
        }
        if let variations = dict["variations"] as? [String: Any] {
            return variations.values.contains { variantGroup in
                guard let group = variantGroup as? [String: Any] else { return false }
                return group.values.contains { hasNonEmptyValue($0) }
            }
        }
        return false
    }

    private func loadCatalog(_ url: URL) throws -> Catalog {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let source = json["sourceLanguage"] as? String ?? ""
        let strings = json["strings"] as? [String: Any] ?? [:]
        var coverage: [String: Set<String>] = [:]
        for (key, entry) in strings {
            var langs: Set<String> = []
            if let e = entry as? [String: Any], let locs = e["localizations"] as? [String: Any] {
                for (lang, node) in locs where hasNonEmptyValue(node) { langs.insert(lang) }
            }
            coverage[key] = langs
        }
        return Catalog(sourceLanguage: source, coverage: coverage)
    }

    private func localizedValue(_ key: String, language: String, in url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = json?["strings"] as? [String: Any]
        let entry = strings?[key] as? [String: Any]
        let localizations = entry?["localizations"] as? [String: Any]
        let localization = localizations?[language] as? [String: Any]
        let unit = localization?["stringUnit"] as? [String: Any]
        return unit?["value"] as? String
    }

    func testSourceLanguageIsEnglish() throws {
        XCTAssertEqual(try loadCatalog(appCatalog).sourceLanguage, "en")
        XCTAssertEqual(try loadCatalog(mobileCatalog).sourceLanguage, "en")
        XCTAssertEqual(try loadCatalog(packageCatalog).sourceLanguage, "en")
    }

    func testMergeAllProgressTextsAreEnglishAndGerman() throws {
        let texts: [(String, String, String)] = [
            ("duplicates.merging_title", "Merging Duplicates", "Duplikate werden zusammengeführt"),
            ("duplicates.ranking_progress %@ %@", "%1$@ of %2$@ groups", "%1$@ von %2$@ Gruppen"),
            ("duplicates.stop", "Stop", "Stop"),
            (
                "duplicates.merge_stopped %@ %@", "Merging stopped. %1$@ of %2$@ groups were merged.",
                "Zusammenführen gestoppt. %1$@ von %2$@ Gruppen wurden zusammengeführt."
            ),
        ]
        for (key, english, german) in texts {
            XCTAssertEqual(try localizedValue(key, language: "en", in: packageCatalog), english, key)
            XCTAssertEqual(try localizedValue(key, language: "de", in: packageCatalog), german, key)
        }
    }

    func testDuplicateThumbnailUnavailableLabelIsEnglishAndGerman() throws {
        let key = "duplicates.thumbnail_unavailable"
        XCTAssertEqual(try localizedValue(key, language: "en", in: packageCatalog), "Thumbnail unavailable")
        XCTAssertEqual(try localizedValue(key, language: "de", in: packageCatalog), "Vorschaubild nicht verfügbar")
    }

    func testEveryRetryActionHasOneTryAgainTitle() throws {
        XCTAssertEqual(try localizedValue("action.retry", language: "en", in: packageCatalog), "Try again")
        XCTAssertEqual(try localizedValue("action.retry", language: "de", in: packageCatalog), "Erneut versuchen")
        let retiredKeys = ["action.try_again", "sign_out.try_again", "albums.try_again", "backup.failed_sheet_retry"]
        for catalog in [packageCatalog, appCatalog, mobileCatalog] {
            let keys = try loadCatalog(catalog).coverage.keys
            for key in retiredKeys {
                XCTAssertFalse(keys.contains(key), "\(key) duplicates action.retry in \(catalog.lastPathComponent)")
            }
        }
    }

    func testWiFiWaitExplainsThatCellularBackupIsOffInEnglishAndGerman() throws {
        let texts = [
            ("backup.phase_waiting_wifi", "Waiting for Wi-Fi", "Wartet auf WLAN"),
            (
                "backup.detail_waiting_wifi", "Cellular data is off for backups.",
                "Mobile Daten sind für Sicherungen aus."
            ),
        ]
        for (key, english, german) in texts {
            XCTAssertEqual(try localizedValue(key, language: "en", in: packageCatalog), english)
            XCTAssertEqual(try localizedValue(key, language: "de", in: packageCatalog), german)
        }
    }

    func testSharedLibraryTitleLivesInCore() throws {
        XCTAssertEqual(try localizedValue("library.title", language: "en", in: packageCatalog), "Library")
        XCTAssertEqual(try localizedValue("library.title", language: "de", in: packageCatalog), "Mediathek")
    }

    func testMadeInAustriaLineIsSharedEnglishOnly() throws {
        let line = "Made with ❤️ in Austria 🇦🇹"
        XCTAssertEqual(try localizedValue("brand.made_in_austria", language: "en", in: packageCatalog), line)
        XCTAssertEqual(try localizedValue("brand.made_in_austria", language: "de", in: packageCatalog), line)
        XCTAssertEqual(ProductBrand.madeInAustria, line)
        XCTAssertNotEqual(ProductBrand.madeInAustria, "brand.made_in_austria")
    }

    func testProductAndProtonTerminology() throws {
        XCTAssertEqual(
            try localizedValue("brand.product_name", language: "en", in: packageCatalog), "Encrypted Memories")
        XCTAssertEqual(
            try localizedValue("brand.product_name", language: "de", in: packageCatalog), "Encrypted Memories")
        XCTAssertEqual(
            try localizedValue("brand.independence_notice", language: "en", in: packageCatalog),
            "Encrypted Memories is not affiliated with or endorsed by Proton AG."
        )
        XCTAssertEqual(
            try localizedValue("login.sign_in_button", language: "en", in: packageCatalog),
            "Log in with Proton"
        )
        XCTAssertEqual(
            try localizedValue("login.account_requirement", language: "en", in: packageCatalog),
            "Existing Proton account required."
        )
        XCTAssertEqual(
            try localizedValue("settings.tip_jar_title", language: "en", in: packageCatalog),
            "Support Encrypted Memories"
        )
    }

    func testAlbumEmptyStateExplainsCreatedAndSyncedAlbums() throws {
        XCTAssertEqual(
            try localizedValue("collections.empty_albums", language: "en", in: mobileCatalog),
            "Albums you create or sync appear here."
        )
        XCTAssertEqual(
            try localizedValue("collections.empty_albums", language: "de", in: mobileCatalog),
            "Deine erstellten oder synchronisierten Alben erscheinen hier."
        )
    }

    func testVisibleCatalogValuesDoNotUseOldProductName() throws {
        let formerProductName = "Proton" + " Photos"
        let formerDescriptiveName = "Photos for " + "Proton Drive"
        for url in [appCatalog, mobileCatalog, packageCatalog] {
            let data = try Data(contentsOf: url)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains(formerProductName), "Old product name remains in \(url.path)")
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains(formerDescriptiveName), "Old product name remains in \(url.path)")
        }
    }

    func testSharedSearchScopesUseProductNames() throws {
        XCTAssertEqual(
            try localizedValue("mlsearch.product_name", language: "en", in: packageCatalog),
            "Smart Search"
        )
        XCTAssertEqual(
            try localizedValue("mlsearch.product_name", language: "de", in: packageCatalog),
            "Intelligente Suche"
        )
        for language in ["en", "de"] {
            XCTAssertEqual(
                try localizedValue("mlsearch.scope_text", language: language, in: packageCatalog),
                "OCR"
            )
        }
        XCTAssertNil(try localizedValue("mlsearch.scope_all", language: "en", in: packageCatalog))
        XCTAssertNil(try localizedValue("mlsearch.settings_title", language: "en", in: packageCatalog))
    }

    func testSmartSearchProductNameIsNotDuplicatedAcrossLocalizedValues() throws {
        let data = try Data(contentsOf: packageCatalog)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let strings = json["strings"] as? [String: Any] ?? [:]
        for (language, productName) in [("en", "Smart Search"), ("de", "Intelligente Suche")] {
            let exactMatches = strings.values.compactMap { entry -> String? in
                let entry = entry as? [String: Any]
                let localizations = entry?["localizations"] as? [String: Any]
                let localization = localizations?[language] as? [String: Any]
                let unit = localization?["stringUnit"] as? [String: Any]
                return unit?["value"] as? String
            }.filter { $0 == productName }
            XCTAssertEqual(exactMatches, [productName])
        }
    }

    func testSharedSelectionAndFileSizePresentation() {
        XCTAssertEqual(L10n.selectionCenterText(selectedCount: -1), L10n.string("selection.select_items"))
        XCTAssertEqual(L10n.selectionCenterText(selectedCount: 0), L10n.string("selection.select_items"))
        XCTAssertEqual(L10n.selectionCenterText(selectedCount: 1), L10n.string("selection.one_selected"))
        XCTAssertEqual(L10n.selectionCenterText(selectedCount: 3), L10n.string("selection.count_selected \(3)"))
        XCTAssertFalse(L10n.fileSize(1_024).isEmpty)
    }

    func testRepresentativeAppKeysHaveEnglishAndGerman() throws {
        let cov = try loadCatalog(appCatalog).coverage
        let reps = [
            "login.tagline", "sidebar.all_photos", "settings.library_tab", "menu.upload_photos",
            "alert.trash_confirmation_title_other %lld",
            "a11y.download_count_selected_originals %lld",
        ]
        for key in reps {
            let langs = cov[key] ?? []
            XCTAssertTrue(langs.contains("en"), "App catalog missing English for \(key)")
            XCTAssertTrue(langs.contains("de"), "App catalog missing German for \(key)")
        }
    }

    func testRepresentativeMobileKeysHaveEnglishAndGerman() throws {
        let cov = try loadCatalog(mobileCatalog).coverage
        let reps = [
            "tab.collections", "loading.library_title", "loading.preparing_count %lld",
            "auth.sign_in_prompt",
            "viewer.share_action", "viewer.move_to_trash_action", "viewer.restore_action",
        ]
        for key in reps {
            let langs = cov[key] ?? []
            XCTAssertTrue(langs.contains("en"), "Mobile catalog missing English for \(key)")
            XCTAssertTrue(langs.contains("de"), "Mobile catalog missing German for \(key)")
        }
    }

    func testRepresentativePackageKeysHaveEnglishAndGerman() throws {
        let cov = try loadCatalog(packageCatalog).coverage
        let reps = [
            "tag.favorites", "error.video.not_a_video", "upload.state_queued",
            "upload.queue_stats %lld %lld %lld", "action.retry", "infopanel.dimensions",
            "empty.no_photos_title", "empty.trash_title", "library.title", "action.cancel",
            "settings.photos_backup_explainer", "map.empty_message", "selection.select_items",
            "auth.progress_waiting_for_browser", "sign_out.confirmation_title %@",
            "sign_out.confirmation_message", "brand.independence_notice",
            "login.account_requirement", "settings.tip_jar_title",
            "settings.bug_report_action", "settings.bug_report_privacy",
            "settings.bug_report_download", "settings.bug_report_support",
            "settings.bug_report_support_failed",
            "device.requires_metal3 %@",
            "device.unsupported_reassurance", "device.unsupported_title",
            "albums.photo_count %lld",
        ]
        for key in reps {
            let langs = cov[key] ?? []
            XCTAssertTrue(langs.contains("en"), "Package catalog missing English for \(key)")
            XCTAssertTrue(langs.contains("de"), "Package catalog missing German for \(key)")
        }
    }

    func testEveryKeyHasEnglishAndGerman() throws {
        for (name, url) in [("App", appCatalog), ("Mobile", mobileCatalog), ("Package", packageCatalog)] {
            let cov = try loadCatalog(url).coverage
            XCTAssertFalse(cov.isEmpty, "\(name) catalog is empty")
            for (key, langs) in cov {
                XCTAssertTrue(langs.contains("en"), "\(name) catalog: \(key) has no English value")
                XCTAssertTrue(langs.contains("de"), "\(name) catalog: \(key) has no German value")
            }
        }
    }

    func testEveryLocalizationKeyHasExactlyOneOwningCatalog() throws {
        let catalogs = [
            "macOS": try loadCatalog(appCatalog).coverage,
            "iOS": try loadCatalog(mobileCatalog).coverage,
            "Core": try loadCatalog(packageCatalog).coverage,
        ]
        let names = Array(catalogs.keys).sorted()
        for firstIndex in names.indices {
            for secondIndex in names.indices where secondIndex > firstIndex {
                let first = names[firstIndex]
                let second = names[secondIndex]
                let duplicates = Set(catalogs[first]!.keys).intersection(catalogs[second]!.keys)
                XCTAssertTrue(
                    duplicates.isEmpty,
                    "\(first) and \(second) both own localization keys: \(duplicates.sorted())"
                )
            }
        }
    }

    //
    // note: String Catalogs are compiled to `.lproj/.strings` by Xcode's build system (xcstringstool).
    // Plain command-line SwiftPM (`swift build`/`swift test`) copies the raw `.xcstrings` into the bundle
    // *without* compiling it, so at runtime under `swift test` the package facade can't resolve the
    // catalog. The shipping app is built with `xcodebuild`, where these resolve correctly (verified by
    // the presence of `de.lproj` in the built app and package bundles). The runtime-resolution checks
    // below therefore skip when the catalog isn't compiled, so `swift test` stays green while the checks
    // still run (and pass) under an Xcode build. The catalog-content checks above need no such guard.

    /// Whether the package String Catalog was compiled into the resource bundle (Xcode build) vs. copied
    /// raw (plain SwiftPM).
    private var catalogCompiledIntoBundle: Bool {
        L10n.resourceBundle.localizations.contains("de")
    }

    func testPackageBundleAdvertisesEnglishAndGerman() throws {
        try XCTSkipUnless(
            catalogCompiledIntoBundle,
            "String Catalog not compiled (plain SwiftPM build) - validated under xcodebuild.")
        let available = Set(L10n.resourceBundle.localizations)
        XCTAssertTrue(available.contains("en"), "package bundle should advertise English")
        XCTAssertTrue(available.contains("de"), "package bundle should advertise German")
    }

    func testUnsupportedLanguageFallsBackToEnglish() {
        // A user who prefers an unsupported language (French) resolves to the development language. This
        // exercises the fallback resolution regardless of whether German is compiled into the bundle.
        let available = L10n.resourceBundle.localizations
        let resolved = Bundle.preferredLocalizations(from: available, forPreferences: ["fr-FR", "fr"]).first
        XCTAssertEqual(resolved, "en", "unsupported language should fall back to English")
    }

    func testFacadeResolvesAKnownKey() throws {
        try XCTSkipUnless(
            catalogCompiledIntoBundle,
            "String Catalog not compiled (plain SwiftPM build) - validated under xcodebuild.")
        // The facade returns a real translation, not the raw key.
        let favorites = L10n.string("tag.favorites")
        XCTAssertFalse(favorites.isEmpty)
        XCTAssertNotEqual(favorites, "tag.favorites")
    }

    func testNoReintroducedHardcodedGermanUIStrings() {
        // Specific phrases belong only in the catalogs. Search quoted literals so prose and comments
        // do not trip the guard. (Intentional
        // inline locale fallbacks such as ViewerTitleFormatter's "Foto"/"von" are deliberately excluded.)
        let forbidden = [
            "\"Wiedergabe fehlgeschlagen\"",
            "\"Offline-Mediathek\"",
            "\"Originale & Videos offline behalten\"",
            "\"Dies ist kein Video.\"",
            "\"Mediathek / Offline\"",
            "\"Offline-Cache löschen",
        ]
        let roots = [
            repoRoot.appendingPathComponent("App"),
            repoRoot.appendingPathComponent("iOSApp"),
            repoRoot.appendingPathComponent("Packages/EncryptedMemoriesKit/Sources"),
        ]
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" {
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                for phrase in forbidden {
                    XCTAssertFalse(
                        text.contains(phrase),
                        "\(url.lastPathComponent) reintroduced a hardcoded German UI string: \(phrase)")
                }
            }
        }
    }
}
