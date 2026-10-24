import Testing

@testable import PhotosCore

/// Export names: a repeated name, in any letter case, gets a number before its extension.
@Suite struct UniqueNamesTests {
    @Test func aNameThatDiffersOnlyInCaseGetsANumber() async {
        let names = UniqueNames()
        #expect(await names.unique("IMG_0001.HEIC") == "IMG_0001.HEIC")
        #expect(await names.unique("img_0001.heic") == "img_0001 2.heic")
    }

    @Test func aNameWithoutExtensionGetsANumberAtTheEnd() async {
        let names = UniqueNames()
        #expect(await names.unique("name") == "name")
        #expect(await names.unique("name") == "name 2")
    }
}
