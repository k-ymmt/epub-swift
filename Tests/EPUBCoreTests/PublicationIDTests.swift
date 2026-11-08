import Foundation
import Testing
@testable import EPUBCore

@Suite struct PublicationIDTests {
    @Test func roundTripsThroughDescription() {
        let id = PublicationID()
        let parsed = PublicationID(id.description)
        #expect(parsed == id)
        #expect(id.description == id.description.lowercased())
    }

    @Test func fixturesArePresent() {
        #expect(FileManager.default.fileExists(atPath: Fixtures.mobyDick.path))
        #expect(FileManager.default.fileExists(atPath: Fixtures.childrensLiterature.path))
        #expect(FileManager.default.fileExists(atPath: Fixtures.url("malformed/single-missing-close.xhtml").path))
    }
}
