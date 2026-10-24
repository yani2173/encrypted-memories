import CryptoKit
import Foundation
import Testing

@Suite(.serialized, CompiledReleaseScript()) struct MLModelReleaseAutomationTests {
    @Test func qualifiedCandidateProducesSignedCatalogAndEvidenceWithoutPublishing() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The release workflows run the script with `xcrun swift`; this test keeps that form.
        let result = try runRelease(fixture, interpreted: true)

        #expect(result.status == 0, Comment(rawValue: result.error))
        let catalog = try Data(contentsOf: fixture.output.appendingPathComponent("catalog-v1.json"))
        let signature = try Data(contentsOf: fixture.output.appendingPathComponent("catalog-v1.sig"))
        let catalogV2 = try Data(contentsOf: fixture.output.appendingPathComponent("catalog-v2.json"))
        let signatureV2 = try Data(contentsOf: fixture.output.appendingPathComponent("catalog-v2.sig"))
        let publicKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(contentsOf: fixture.privateKey)
        ).publicKey
        #expect(publicKey.isValidSignature(signature, for: catalog))
        #expect(publicKey.isValidSignature(signatureV2, for: catalogV2))
        let catalogJSON = try #require(JSONSerialization.jsonObject(with: catalog) as? [String: Any])
        let catalogModels = try #require(catalogJSON["models"] as? [[String: Any]])
        let catalogQualification = try #require(catalogModels.first?["qualification"] as? [String: Any])
        #expect(catalogQualification["passed"] as? Bool == true)
        #expect(catalogQualification["neuralEngineExecutionVerified"] as? Bool == true)
        let catalogV2JSON = try #require(JSONSerialization.jsonObject(with: catalogV2) as? [String: Any])
        #expect(catalogV2JSON["catalogSequence"] as? Int == 1)
        for name in [
            "provenance-v1.json", "release-evidence-v1.json", "sbom.spdx.json",
            "MODEL-LICENSES.txt", "release-pair.json", "release-pair.sha256", "active-pair.json", "publish-r2.sh",
        ] {
            #expect(FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent(name).path))
        }
        let pairID = try String(
            contentsOf: fixture.output.appendingPathComponent("release-pair.sha256"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let pointer = try Self.loadJSON(fixture.output.appendingPathComponent("active-pair.json"))
        let pointerPayload = try #require(pointer["payload"] as? [String: Any])
        #expect(pointerPayload["pairID"] as? String == pairID)
        #expect((pointerPayload["objects"] as? [[String: Any]])?.count == 5)
        let sbomData = try Data(contentsOf: fixture.output.appendingPathComponent("sbom.spdx.json"))
        let sbom = try #require(JSONSerialization.jsonObject(with: sbomData) as? [String: Any])
        let packages = try #require(sbom["packages"] as? [[String: Any]])
        #expect(packages.first?["filesAnalyzed"] as? Bool == false)
        #expect(packages.first?["licenseDeclared"] as? String == "Apache-2.0")
        #expect(
            sbom["documentNamespace"] as? String
                == "https://models.oncloud.at/model-releases/\(pairID)/sbom.spdx.json"
        )
        let syntax = try Self.run(
            executable: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-n", fixture.output.appendingPathComponent("publish-r2.sh").path]
        )
        #expect(syntax.status == 0, Comment(rawValue: syntax.error))
        let publisher = try String(contentsOf: fixture.output.appendingPathComponent("publish-r2.sh"), encoding: .utf8)
        #expect(publisher.contains("if-none-match"))
        #expect(publisher.contains("NoRedirect"))
        #expect(publisher.contains("data=file_chunks(file_path)"))
        #expect(!publisher.contains("open(file_path, \"rb\").read()"))
        #expect(publisher.contains("headers[\"content-type\"]"))
        #expect(publisher.contains("active-pair.json is the only mutable activation object"))
        #expect(publisher.components(separatedBy: "r2_request PUT active-pair.json").count - 1 == 1)
        let v1SignatureMirror = try #require(publisher.range(of: "publish_catalog_mirror 'catalog-v1.sig'"))
        let v1CatalogMirror = try #require(publisher.range(of: "publish_catalog_mirror 'catalog-v1.json'"))
        let v2SignatureMirror = try #require(publisher.range(of: "publish_catalog_mirror 'catalog-v2.sig'"))
        let v2CatalogMirror = try #require(publisher.range(of: "publish_catalog_mirror 'catalog-v2.json'"))
        let pointerActivation = try #require(publisher.range(of: "publish_pointer '"))
        #expect(v1SignatureMirror.lowerBound < v1CatalogMirror.lowerBound)
        #expect(v1CatalogMirror.lowerBound < v2SignatureMirror.lowerBound)
        #expect(v2SignatureMirror.lowerBound < v2CatalogMirror.lowerBound)
        #expect(v2CatalogMirror.lowerBound < pointerActivation.lowerBound)
        #expect(!publisher.contains("rclone copyto"))
        #expect(!publisher.contains("aws s3"))
        let generatedPython = fixture.root.appendingPathComponent("generated-r2-request.py")
        try Self.embeddedPython(in: publisher).write(to: generatedPython, atomically: true, encoding: .utf8)
        let generatedPythonSyntax = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-m", "py_compile", generatedPython.path]
        )
        #expect(generatedPythonSyntax.status == 0, Comment(rawValue: generatedPythonSyntax.error))

        let rollbackSource = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("scripts/rollback-ml-model-release.sh"),
            encoding: .utf8
        )
        #expect(rollbackSource.contains("--artifact-list \"$historical/catalog-v2.json\""))
        let endpointValidation = try #require(rollbackSource.range(of: "R2_ENDPOINT must be an HTTPS URL"))
        let historicalRead = try #require(rollbackSource.range(of: "rclone copyto"))
        #expect(endpointValidation.lowerBound < historicalRead.lowerBound)
        let rollbackPython = fixture.root.appendingPathComponent("rollback-r2-request.py")
        try Self.embeddedPython(in: rollbackSource).write(to: rollbackPython, atomically: true, encoding: .utf8)
        let rollbackPythonSyntax = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-m", "py_compile", rollbackPython.path]
        )
        #expect(rollbackPythonSyntax.status == 0, Comment(rawValue: rollbackPythonSyntax.error))

        let releaseWorkflow = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent(".github/workflows/ml-model-release.yml"),
            encoding: .utf8
        )
        #expect(releaseWorkflow.contains("release-legacy=$PAIR_ID-$attempt"))
        #expect(releaseWorkflow.contains("$public/legacy-$name"))
        #expect(releaseWorkflow.contains("$RUNNER_TEMP/release/$name"))
        #expect(result.output.contains("No remote state was changed"))
    }

    @Test func activePointerVerifierRejectsATamperedSignature() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let release = try runRelease(fixture)
        #expect(release.status == 0, Comment(rawValue: release.error))

        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(contentsOf: fixture.privateKey)
        )
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let verifier = Self.repositoryRoot.appendingPathComponent("scripts/verify-ml-catalog-signature.swift")
        let pointerURL = fixture.output.appendingPathComponent("active-pair.json")
        let accepted = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swift", verifier.path, "--pointer", pointerURL.path, publicKey]
        )
        #expect(accepted.status == 0, Comment(rawValue: accepted.error))

        var pointer = try Self.loadJSON(pointerURL)
        pointer["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        let tamperedURL = fixture.root.appendingPathComponent("tampered-active-pair.json")
        try Self.writeJSON(pointer, to: tamperedURL)
        let rejected = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swift", verifier.path, "--pointer", tamperedURL.path, publicKey]
        )
        #expect(rejected.status != 0)
        #expect(rejected.error.contains("Active pointer signature is invalid"))
    }

    @Test func tamperedArtifactManifestIsRejectedBeforeSigning() throws {
        let fixture = try makeFixture(manifestHash: String(repeating: "0", count: 64))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runRelease(fixture)

        #expect(result.status != 0)
        #expect(result.error.contains("Artifact manifest hash/size mismatch"))
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("catalog-v1.json").path))
    }

    @Test func candidateWithoutDeviceReportIsRejectedBeforeSigning() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runRelease(fixture, includeQualification: false)

        #expect(result.status != 0)
        #expect(result.error.contains("Missing required file"))
        #expect(!FileManager.default.fileExists(atPath: fixture.output.appendingPathComponent("catalog-v1.json").path))
    }

    @Test func failedPhysicalDeviceGateIsRejected() throws {
        let fixture = try makeFixture(runtimeIOSPhysical: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runRelease(fixture)

        #expect(result.status != 0)
        #expect(result.error.contains("Qualification gate failed"))
    }

    @Test func modelPackageCandidateIsAccepted() throws {
        let fixture = try makeFixture(modelPackageExtension: "mlpackage")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runRelease(fixture)

        #expect(result.status == 0, Comment(rawValue: result.error))
        let catalog = try Self.loadJSON(fixture.output.appendingPathComponent("catalog-v2.json"))
        let models = try #require(catalog["models"] as? [[String: Any]])
        let artifacts = try #require(models.first?["artifacts"] as? [[String: Any]])
        #expect(artifacts.contains { ($0["path"] as? String)?.hasPrefix("SigLIP2.mlpackage/") == true })
    }

    @Test func duplicateManifestPathsAreRejectedWithoutCrashing() throws {
        let fixture = try makeFixture(duplicateManifestPath: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runRelease(fixture)

        #expect(result.status != 0)
        #expect(result.error.contains("Artifact manifest contains duplicate paths"))
    }

    @Test func nextReleaseMergesTheVerifiedCatalogPairAtTheNextSequence() throws {
        let first = try makeFixture(modelPayload: "compiled-model-v1")
        let second = try makeFixture(descriptorVersion: 2, modelPayload: "compiled-model-v2")
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        try Data(contentsOf: first.privateKey).write(to: second.privateKey, options: .atomic)
        let firstResult = try runRelease(first)
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.error))

        let secondResult = try runRelease(second, sequence: 2, previousOutput: first.output)

        #expect(secondResult.status == 0, Comment(rawValue: secondResult.error))
        let firstCatalog = try Self.loadJSON(first.output.appendingPathComponent("catalog-v2.json"))
        let secondCatalog = try Self.loadJSON(second.output.appendingPathComponent("catalog-v2.json"))
        #expect(firstCatalog["catalogSequence"] as? Int == 1)
        #expect(secondCatalog["catalogSequence"] as? Int == 2)
        let firstModels = try #require(firstCatalog["models"] as? [[String: Any]])
        let secondModels = try #require(secondCatalog["models"] as? [[String: Any]])
        let firstRevision = try #require(firstModels.first?["revision"] as? String)
        let secondRevision = try #require(secondModels.first?["revision"] as? String)
        #expect(firstRevision != secondRevision)
        #expect(firstModels.first?["releaseSequence"] as? Int == 1)
        #expect(secondModels.first?["releaseSequence"] as? Int == 2)
        let secondDescriptor = try #require(secondModels.first?["descriptor"] as? [String: Any])
        #expect(secondDescriptor["version"] as? Int == 2)
    }

    @Test func retirementOnlyCandidateRejectsRemovingTheFinalV1Model() throws {
        let first = try makeFixture()
        let retirement = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: retirement.root)
        }
        try Data(contentsOf: first.privateKey).write(to: retirement.privateKey, options: .atomic)

        let firstResult = try runRelease(first)
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.error))

        let retirementResult = try runRelease(
            retirement,
            sequence: 2,
            previousOutput: first.output,
            includeModel: false,
            retiredModelIDs: ["siglip2-base-patch16-256"]
        )
        #expect(retirementResult.status != 0)
        #expect(retirementResult.error.contains("Retirement would remove the final V1 model"))
    }

    @Test func onlyThePreviewChannelCanRetireAModelThatShippedAppsCanSelect() throws {
        let first = try makeFixture()
        let retirement = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: retirement.root)
        }
        try Data(contentsOf: first.privateKey).write(to: retirement.privateKey, options: .atomic)
        let firstResult = try runRelease(first)
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.error))

        let production = try runRelease(
            retirement,
            sequence: 2,
            previousOutput: first.output,
            includeModel: false,
            retiredModelIDs: ["siglip2-base-patch16-256"],
            allowEmptyV1: true
        )
        #expect(production.status != 0)
        #expect(production.error.contains("Apps 1.0.5 and earlier lose model siglip2-base-patch16-256"))

        let preview = try runRelease(
            retirement,
            sequence: 2,
            previousOutput: first.output,
            includeModel: false,
            retiredModelIDs: ["siglip2-base-patch16-256"],
            channel: "preview",
            allowEmptyV1: true
        )
        #expect(preview.status == 0, Comment(rawValue: preview.error))
        let catalog = try Self.loadJSON(retirement.output.appendingPathComponent("catalog-v2.json"))
        let models = try #require(catalog["models"] as? [[String: Any]])
        #expect(models.first?["availability"] as? String == "retired")
    }

    @Test func onlyThePreviewChannelCanPublishARecipeThatShippedAppsDoNotKnow() throws {
        let fixture = try makeFixture(modelID: "siglip-next", compatibilityKey: "siglip-dual-encoder-v2")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var compatibility = try Self.loadJSON(
            Self.repositoryRoot.appendingPathComponent("Tools/MLModels/catalog-compatibility.json")
        )
        var recipes = try #require(compatibility["recipes"] as? [[String: Any]])
        var nextRecipe = try #require(recipes.first { $0["key"] as? String == "siglip-dual-encoder-v1" })
        nextRecipe["key"] = "siglip-dual-encoder-v2"
        recipes.append(nextRecipe)
        compatibility["recipes"] = recipes
        let compatibilityURL = fixture.root.appendingPathComponent("catalog-compatibility.json")
        try Self.writeJSON(compatibility, to: compatibilityURL)

        let production = try runRelease(fixture, allowEmptyV1: true, compatibility: compatibilityURL)
        #expect(production.status != 0)
        #expect(production.error.contains("model siglip-next uses unknown recipe siglip-dual-encoder-v2"))

        let preview = try runRelease(
            fixture,
            channel: "preview",
            allowEmptyV1: true,
            compatibility: compatibilityURL
        )
        #expect(preview.status == 0, Comment(rawValue: preview.error))
        let catalog = try Self.loadJSON(fixture.output.appendingPathComponent("catalog-v2.json"))
        let models = try #require(catalog["models"] as? [[String: Any]])
        #expect(models.first?["compatibilityKey"] as? String == "siglip-dual-encoder-v2")
    }

    @Test func v1OnlyMigrationPreservesEveryLegacyModelInV2() throws {
        let first = try makeFixture()
        let migration = try makeFixture(descriptorVersion: 2, modelPayload: "compiled-model-migration")
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: migration.root)
        }
        try Data(contentsOf: first.privateKey).write(to: migration.privateKey, options: .atomic)

        let firstResult = try runRelease(first)
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.error))

        var previousV1 = try Self.loadJSON(first.output.appendingPathComponent("catalog-v1.json"))
        let tinyArtifact: [String: Any] = [
            "path": "TinyCLIP.mlmodelc/weights.bin",
            "url":
                "https://models.oncloud.at/models/tinyclip-vit-40m-32-text-19m/legacy-tiny/TinyCLIP.mlmodelc/weights.bin",
            "sha256": String(repeating: "a", count: 64),
            "bytes": 12,
        ]
        let existingModels = try #require(previousV1["models"] as? [[String: Any]])
        previousV1["models"] =
            existingModels + [
                [
                    "id": "tinyclip-vit-40m-32-text-19m",
                    "revision": "legacy-tiny",
                    "artifacts": [tinyArtifact],
                ]
            ]
        let previousV1URL = first.root.appendingPathComponent("previous-catalog-v1.json")
        let previousV1Data = try JSONSerialization.data(
            withJSONObject: previousV1, options: [.prettyPrinted, .sortedKeys])
        try previousV1Data.write(to: previousV1URL)
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(contentsOf: first.privateKey)
        )
        try key.signature(for: previousV1Data).write(
            to: first.root.appendingPathComponent("previous-catalog-v1.sig")
        )

        let migrationResult = try runRelease(
            migration,
            previousV1Only: (
                previousV1URL,
                first.root.appendingPathComponent("previous-catalog-v1.sig")
            )
        )
        #expect(migrationResult.status == 0, Comment(rawValue: migrationResult.error))
        let migratedV1 = try Self.loadJSON(migration.output.appendingPathComponent("catalog-v1.json"))
        let migratedV2 = try Self.loadJSON(migration.output.appendingPathComponent("catalog-v2.json"))
        let v1Models = try #require(migratedV1["models"] as? [[String: Any]])
        let v2Models = try #require(migratedV2["models"] as? [[String: Any]])
        #expect(
            Set(v1Models.compactMap { $0["id"] as? String })
                == Set([
                    "siglip2-base-patch16-256", "tinyclip-vit-40m-32-text-19m",
                ]))
        #expect(
            Set(v2Models.compactMap { $0["id"] as? String })
                == Set([
                    "siglip2-base-patch16-256", "tinyclip-vit-40m-32-text-19m",
                ]))
        let tinyV1 = try #require(v1Models.first { $0["id"] as? String == "tinyclip-vit-40m-32-text-19m" })
        let tinyV2 = try #require(v2Models.first { $0["id"] as? String == "tinyclip-vit-40m-32-text-19m" })
        let tinyV1Revision = try #require(tinyV1["revision"] as? String)
        #expect(tinyV2["revision"] as? String == tinyV1Revision)
        let tinyV1Artifacts = try #require(tinyV1["artifacts"] as? [[String: Any]])
        let tinyV2Artifacts = try #require(tinyV2["artifacts"] as? [[String: Any]])
        #expect(tinyV2Artifacts.count == tinyV1Artifacts.count)
        #expect(tinyV2Artifacts.first?["sha256"] as? String == tinyV1Artifacts.first?["sha256"] as? String)
    }

    @Test func v1OnlyMigrationRejectsAnArtifactPlanThatCannotBeReused() throws {
        let first = try makeFixture()
        let migration = try makeFixture(descriptorVersion: 2, modelPayload: "compiled-model-migration")
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: migration.root)
        }
        try Data(contentsOf: first.privateKey).write(to: migration.privateKey, options: .atomic)

        let firstResult = try runRelease(first)
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.error))
        var previousV1 = try Self.loadJSON(first.output.appendingPathComponent("catalog-v1.json"))
        var models = try #require(previousV1["models"] as? [[String: Any]])
        var model = try #require(models.first)
        var artifacts = try #require(model["artifacts"] as? [[String: Any]])
        artifacts[0]["url"] = "https://models.oncloud.at/models/not-the-catalog-path"
        model["artifacts"] = artifacts
        models[0] = model
        previousV1["models"] = models
        let previousV1URL = first.root.appendingPathComponent("previous-catalog-v1.json")
        let previousV1Data = try JSONSerialization.data(
            withJSONObject: previousV1, options: [.prettyPrinted, .sortedKeys])
        try previousV1Data.write(to: previousV1URL)
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(contentsOf: first.privateKey)
        )
        let previousSignatureURL = first.root.appendingPathComponent("previous-catalog-v1.sig")
        try key.signature(for: previousV1Data).write(to: previousSignatureURL)

        let migrationResult = try runRelease(
            migration,
            previousV1Only: (previousV1URL, previousSignatureURL)
        )
        #expect(migrationResult.status != 0)
        #expect(migrationResult.error.contains("cannot safely reuse artifact metadata"))
    }

    @Test func changedWeightsRequireTheNextDescriptorVersion() throws {
        let first = try makeFixture(modelPayload: "compiled-model-v1")
        let second = try makeFixture(modelPayload: "compiled-model-v2")
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: second.root)
        }
        try Data(contentsOf: first.privateKey).write(to: second.privateKey, options: .atomic)
        let firstResult = try runRelease(first)
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.error))

        let secondResult = try runRelease(second, sequence: 2, previousOutput: first.output)

        #expect(secondResult.status != 0)
        #expect(secondResult.error.contains("must increment descriptorVersion by one"))
    }

    @Test func unchangedCandidateRequiresAnExplicitRecoveryRelease() throws {
        let first = try makeFixture()
        let retry = try makeFixture()
        defer {
            try? FileManager.default.removeItem(at: first.root)
            try? FileManager.default.removeItem(at: retry.root)
        }
        try Data(contentsOf: first.privateKey).write(to: retry.privateKey, options: .atomic)
        let firstResult = try runRelease(first)
        #expect(firstResult.status == 0, Comment(rawValue: firstResult.error))

        let rejected = try runRelease(retry, sequence: 2, previousOutput: first.output)
        #expect(rejected.status != 0)
        #expect(rejected.error.contains("does not change model"))

        let recovery = try runRelease(
            retry,
            sequence: 2,
            previousOutput: first.output,
            allowUnchangedCandidate: true
        )
        #expect(recovery.status == 0, Comment(rawValue: recovery.error))
        let catalog = try Self.loadJSON(retry.output.appendingPathComponent("catalog-v2.json"))
        let models = try #require(catalog["models"] as? [[String: Any]])
        #expect(models.first?["releaseSequence"] as? Int == 2)
    }

    @Test func rollbackCreatesANewForwardSequenceForBothCatalogs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let release = try runRelease(fixture)
        #expect(release.status == 0, Comment(rawValue: release.error))

        let rollbackOutput = fixture.root.appendingPathComponent("rollback", isDirectory: true)
        let script = Self.repositoryRoot.appendingPathComponent("scripts/prepare-ml-model-rollback.swift")
        let sourcePair = try String(
            contentsOf: fixture.output.appendingPathComponent("release-pair.sha256"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swift", script.path,
                "--catalog-v1", fixture.output.appendingPathComponent("catalog-v1.json").path,
                "--catalog-v2", fixture.output.appendingPathComponent("catalog-v2.json").path,
                "--private-key", fixture.privateKey.path,
                "--output", rollbackOutput.path,
                "--catalog-sequence", "2",
                "--repository-revision", String(repeating: "d", count: 40),
                "--released-at", "2026-08-25T21:00:00Z",
                "--source-pair", sourcePair,
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.error))
        let oldV1 = try Data(contentsOf: fixture.output.appendingPathComponent("catalog-v1.json"))
        let rollbackV1 = try Data(contentsOf: rollbackOutput.appendingPathComponent("catalog-v1.json"))
        #expect(oldV1 == rollbackV1)
        let rollbackV2 = try Self.loadJSON(rollbackOutput.appendingPathComponent("catalog-v2.json"))
        #expect(rollbackV2["catalogSequence"] as? Int == 2)
        let rollbackModels = try #require(rollbackV2["models"] as? [[String: Any]])
        #expect(rollbackModels.first?["releaseSequence"] as? Int == 2)
        let pair = try Self.loadJSON(rollbackOutput.appendingPathComponent("release-pair.json"))
        #expect(pair["rollbackSourcePair"] as? String == sourcePair)
    }

    @Test func rollbackPreservesOptionalAvailabilityAndVerifiesRetiredRows() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let release = try runRelease(fixture)
        #expect(release.status == 0, Comment(rawValue: release.error))

        var catalog = try Self.loadJSON(fixture.output.appendingPathComponent("catalog-v2.json"))
        var catalogModels = try #require(catalog["models"] as? [[String: Any]])
        var active = try #require(catalogModels.first)
        active.removeValue(forKey: "availability")
        var retired = active
        retired["id"] = "retired-model"
        retired["availability"] = "retired"
        catalogModels = [active, retired]
        catalog["models"] = catalogModels
        try Self.writeJSON(catalog, to: fixture.output.appendingPathComponent("catalog-v2.json"))

        let rollbackOutput = fixture.root.appendingPathComponent("rollback-retired", isDirectory: true)
        let script = Self.repositoryRoot.appendingPathComponent("scripts/prepare-ml-model-rollback.swift")
        let sourcePair = try String(
            contentsOf: fixture.output.appendingPathComponent("release-pair.sha256"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let result = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "swift", script.path,
                "--catalog-v1", fixture.output.appendingPathComponent("catalog-v1.json").path,
                "--catalog-v2", fixture.output.appendingPathComponent("catalog-v2.json").path,
                "--private-key", fixture.privateKey.path,
                "--output", rollbackOutput.path,
                "--catalog-sequence", "2",
                "--repository-revision", String(repeating: "d", count: 40),
                "--released-at", "2026-08-25T21:00:00Z",
                "--source-pair", sourcePair,
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.error))
        let rollbackCatalog = try Self.loadJSON(rollbackOutput.appendingPathComponent("catalog-v2.json"))
        let rollbackModels = try #require(rollbackCatalog["models"] as? [[String: Any]])
        let rollbackActive = try #require(
            rollbackModels.first { $0["id"] as? String == "siglip2-base-patch16-256" }
        )
        let rollbackRetired = try #require(
            rollbackModels.first { $0["id"] as? String == "retired-model" }
        )
        #expect(rollbackActive["availability"] == nil)
        #expect(rollbackRetired["availability"] as? String == "retired")
        #expect(rollbackActive["releaseSequence"] as? Int == 2)
        #expect(rollbackRetired["releaseSequence"] as? Int == 2)

        let verifier = Self.repositoryRoot.appendingPathComponent("scripts/verify-ml-release-pair.py")
        let verification = try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: [verifier.path, rollbackOutput.path]
        )
        #expect(verification.status == 0, Comment(rawValue: verification.error))
    }

    private struct Fixture {
        let root: URL
        let model: URL
        let evidence: URL
        let qualification: URL
        let notices: URL
        let output: URL
        let privateKey: URL
        let modelID: String
    }

    private func makeFixture(
        manifestHash: String? = nil,
        runtimeIOSPhysical: Bool = true,
        duplicateManifestPath: Bool = false,
        descriptorVersion: Int = 1,
        modelPackageExtension: String = "mlmodelc",
        modelPayload: String = "compiled-model",
        modelID: String = "siglip2-base-patch16-256",
        compatibilityKey: String = "siglip-dual-encoder-v1"
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-release-tests-\(UUID().uuidString)", isDirectory: true)
        let model = root.appendingPathComponent("model", isDirectory: true)
        let modelRootName = "SigLIP2.\(modelPackageExtension)"
        let compiled = model.appendingPathComponent(modelRootName, isDirectory: true)
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        let qualification = root.appendingPathComponent("qualification", isDirectory: true)
        let notices = root.appendingPathComponent("notices", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: qualification, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: notices, withIntermediateDirectories: true)

        let modelData = Data(modelPayload.utf8)
        let tokenizerData = Data("tokenizer".utf8)
        let modelFile = compiled.appendingPathComponent("weights.bin")
        let tokenizerFile = model.appendingPathComponent("tokenizer.json")
        try modelData.write(to: modelFile)
        try tokenizerData.write(to: tokenizerFile)
        let modelHash = Self.sha256(modelData)
        let tokenizerHash = Self.sha256(tokenizerData)
        let rows = [
            ("\(modelRootName)/weights.bin", modelHash, modelData.count),
            ("tokenizer.json", tokenizerHash, tokenizerData.count),
        ]
        let fingerprint =
            ([
                "modelID:\(modelID)",
                "compatibilityKey:\(compatibilityKey)",
                "sourceRevision:3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
                "descriptorVersion:\(descriptorVersion)",
                "embeddingDimension:768",
                "role:dualEncoder",
                "capabilities:imageEmbedding,textEmbedding",
                "licenseIdentifier:Apache-2.0",
            ] + rows.map { "\($0.0):\($0.1):\($0.2)" }).joined(separator: "\n")
        let artifactRevision =
            "r1-"
            + SHA256.hash(data: Data(fingerprint.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        var manifestFiles: [[String: Any]] = [
            ["path": rows[0].0, "bytes": rows[0].2, "sha256": manifestHash ?? rows[0].1],
            ["path": rows[1].0, "bytes": rows[1].2, "sha256": rows[1].1],
        ]
        if duplicateManifestPath { manifestFiles.append(manifestFiles[0]) }
        let manifest: [String: Any] = [
            "schema_version": 1,
            "revision": "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
            "tools": ["coremltools": "9.0"],
            "files": manifestFiles,
        ]
        try Self.writeJSON(manifest, to: model.appendingPathComponent("artifact-manifest.json"))
        let releaseManifest: [String: Any] = [
            "schemaVersion": 1,
            "modelID": modelID,
            "compatibilityKey": compatibilityKey,
            "sourceRevision": "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
            "descriptorVersion": descriptorVersion,
            "embeddingDimension": 768,
            "role": "dualEncoder",
            "capabilities": ["imageEmbedding", "textEmbedding"],
            "licenseIdentifier": "Apache-2.0",
        ]
        try Self.writeJSON(releaseManifest, to: model.appendingPathComponent("release-manifest.json"))

        let gates: [String: Any] = [
            "sourceCoreMLNumerics": true,
            "tokenizerCompatibility": true,
            "searchQuality": true,
            "modelTokenizerPair": true,
            "licenseAndProvenance": true,
            "artifactSizeAndDisk": true,
            "runtimeMacOS": true,
            "runtimeIOSPhysical": runtimeIOSPhysical,
        ]
        let report: [String: Any] = [
            "schemaVersion": 1,
            "modelID": modelID,
            "sourceRevision": "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
            "artifactRevision": artifactRevision,
            "converterRevision": String(repeating: "a", count: 40),
            "qualificationCorpusRevision": String(repeating: "b", count: 40),
            "xcodeBuild": "17F113",
            "coremltoolsVersion": "9.0",
            "hardwareModel": "iPhone-test",
            "osVersion": "26.0",
            "peakResidentBytes": 100_000_000,
            "imageP95Milliseconds": 10.0,
            "textP95Milliseconds": 5.0,
            "reachedSeriousThermalState": false,
            "neuralEngineExecutionVerified": true,
            "gates": gates,
        ]
        try Self.writeJSON(
            report,
            to: qualification.appendingPathComponent("\(modelID).json")
        )
        let notice = Data("Apache-2.0 test notice".utf8)
        let noticeURL = notices.appendingPathComponent("\(modelID).txt")
        try notice.write(to: noticeURL)
        let releaseEvidence: [String: Any] = [
            "schemaVersion": 1,
            "modelID": modelID,
            "sourceRevision": "3f9f96cb90da5dbc758b01813f2f6f1aee24c1ab",
            "sourceURL": "https://example.test/models/siglip2",
            "licenseIdentifier": "Apache-2.0",
            "licenseURL": "https://example.test/licenses/apache-2.0",
            "noticeSHA256": Self.sha256(notice),
            "rights": [
                "productUse": true,
                "commercialUse": true,
                "modification": true,
                "formatConversion": true,
                "redistribution": true,
                "appStoreDistribution": true,
            ],
        ]
        try Self.writeJSON(
            releaseEvidence,
            to: evidence.appendingPathComponent("\(modelID).json")
        )
        let privateKey = root.appendingPathComponent("catalog.key")
        try Curve25519.Signing.PrivateKey().rawRepresentation.write(to: privateKey)
        return Fixture(
            root: root,
            model: model,
            evidence: evidence,
            qualification: qualification,
            notices: notices,
            output: output,
            privateKey: privateKey,
            modelID: modelID
        )
    }

    private func runRelease(
        _ fixture: Fixture,
        includeQualification: Bool = true,
        sequence: UInt64 = 1,
        previousOutput: URL? = nil,
        previousV1Only: (catalog: URL, signature: URL)? = nil,
        allowUnchangedCandidate: Bool = false,
        includeModel: Bool = true,
        retiredModelIDs: [String] = [],
        channel: String? = nil,
        allowEmptyV1: Bool = false,
        compatibility: URL? = nil,
        interpreted: Bool = false
    ) throws -> (status: Int32, output: String, error: String) {
        var arguments = [
            "--private-key", fixture.privateKey.path,
            "--output", fixture.output.path,
            "--bucket", "test-bucket",
            "--base-url", "https://models.oncloud.at/models/",
            "--candidate-root", fixture.root.path,
            "--evidence-dir", fixture.evidence.path,
            "--notices-dir", fixture.notices.path,
            "--repository-revision", String(repeating: "c", count: 40),
            "--released-at", "2026-08-25T20:00:00Z",
            "--catalog-sequence", String(sequence),
        ]
        if includeModel {
            arguments += ["--model", "\(fixture.modelID)=\(fixture.model.path)"]
        }
        if !retiredModelIDs.isEmpty {
            let manifestURL = fixture.root.appendingPathComponent("retired-models.json")
            try Self.writeJSON(
                ["schemaVersion": 1, "modelIDs": retiredModelIDs],
                to: manifestURL
            )
            arguments += ["--retired-models", manifestURL.path]
        }
        if includeQualification {
            arguments += ["--qualification-dir", fixture.qualification.path]
        } else {
            arguments += ["--qualification-dir", fixture.root.appendingPathComponent("missing-qualification").path]
        }
        if let previousV1Only {
            arguments += [
                "--previous-catalog-v1", previousV1Only.catalog.path,
                "--previous-signature-v1", previousV1Only.signature.path,
            ]
        } else if let previousOutput {
            arguments += [
                "--previous-catalog-v1", previousOutput.appendingPathComponent("catalog-v1.json").path,
                "--previous-signature-v1", previousOutput.appendingPathComponent("catalog-v1.sig").path,
                "--previous-catalog-v2", previousOutput.appendingPathComponent("catalog-v2.json").path,
                "--previous-signature-v2", previousOutput.appendingPathComponent("catalog-v2.sig").path,
            ]
        }
        if allowUnchangedCandidate {
            arguments.append("--allow-unchanged-candidate")
        }
        if allowEmptyV1 {
            arguments.append("--allow-empty-v1")
        }
        if let channel {
            arguments += ["--channel", channel]
        }
        if let compatibility {
            arguments += ["--compatibility", compatibility.path]
        }
        guard interpreted else {
            guard let binary = CompiledReleaseScript.binary else {
                throw CompiledReleaseScript.Failure(description: "the suite did not compile the release script")
            }
            return try Self.run(executable: binary, arguments: arguments)
        }
        return try Self.run(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["swift", CompiledReleaseScript.source.path] + arguments
        )
    }

    private static func run(
        executable: URL,
        arguments: [String]
    ) throws -> (status: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    fileprivate static var repositoryRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeJSON(_ object: Any, to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
    }

    private static func loadJSON(_ url: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private static func embeddedPython(in source: String) throws -> String {
        let start = try #require(source.range(of: "<<'PY'\n")?.upperBound)
        let end = try #require(source.range(of: "\nPY\n", range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}

/// Compiles `prepare-ml-model-release.swift` once for the suite, so each release run starts a binary instead of
/// compiling 1,900 lines again. The binary lives in a temporary directory that the suite removes afterwards.
private struct CompiledReleaseScript: SuiteTrait, TestScoping {
    static let source = MLModelReleaseAutomationTests.repositoryRoot.appendingPathComponent(
        "scripts/prepare-ml-model-release.swift")

    @TaskLocal static var binary: URL?

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLModelReleaseAutomationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("prepare-ml-model-release")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", Self.source.path, "-o", binary.path]
        let errors = Pipe()
        compiler.standardError = errors
        try compiler.run()
        let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            throw Failure(description: String(decoding: diagnostics, as: UTF8.self))
        }
        try await Self.$binary.withValue(binary, operation: function)
    }
}
