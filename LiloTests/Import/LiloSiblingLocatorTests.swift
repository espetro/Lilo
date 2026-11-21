import XCTest
@testable import Lilo

final class LiloSiblingLocatorTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeSupportFolder(_ name: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/\(name)"),
                                                withIntermediateDirectories: true)
    }

    func testFindsReleaseLiloFromBeta() throws {
        try makeSupportFolder("Lilo")
        let url = LiloSiblingLocator.supportDirectory(bundleId: "fr.arouillard.lilo", home: home,
                                                      ownBundleId: "fr.arouillard.lilo.beta")
        XCTAssertEqual(url, home.appendingPathComponent("Library/Application Support/Lilo"))
    }

    func testFindsBetaFromReleaseAndIgnoresOwnFolder() throws {
        try makeSupportFolder("Lilo-Beta")
        XCTAssertEqual(try LiloSiblingLocator.supportDirectory(bundleId: "fr.arouillard.lilo.beta", home: home,
                                                               ownBundleId: "fr.arouillard.lilo"),
                       home.appendingPathComponent("Library/Application Support/Lilo-Beta"))
        // A build never imports from itself, even when its own folder exists.
        XCTAssertNil(LiloSiblingLocator.supportDirectory(bundleId: "fr.arouillard.lilo.beta", home: home,
                                                         ownBundleId: "fr.arouillard.lilo.beta"))
    }

    func testNilWhenFolderMissingOrUnknownBundleId() throws {
        XCTAssertNil(LiloSiblingLocator.supportDirectory(bundleId: "fr.arouillard.lilo", home: home,
                                                         ownBundleId: "fr.arouillard.lilo.beta"))
        try makeSupportFolder("Lilo")
        XCTAssertNil(LiloSiblingLocator.supportDirectory(bundleId: "com.example.other", home: home,
                                                         ownBundleId: "fr.arouillard.lilo.beta"))
    }

    func testNilWhenPathIsAFile() throws {
        let file = home.appendingPathComponent("Library/Application Support/Lilo")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        XCTAssertNil(LiloSiblingLocator.supportDirectory(bundleId: "fr.arouillard.lilo", home: home,
                                                         ownBundleId: "fr.arouillard.lilo.beta"))
    }
}
