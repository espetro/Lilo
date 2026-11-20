import Foundation

/// Locates another Lilo build's Application Support directory by bundle id, so the beta can offer
/// "Import from existing Lilo" without ever writing to the source. Pure path arithmetic: everything
/// is testable against a fake home directory.
enum LiloSiblingLocator {
    /// The App Support folder name each bundle id maps to, mirroring BuildIdentity's data folders.
    private static let folderNames = [
        "fr.arouillard.lilo": "Lilo", "fr.arouillard.lilo.beta": "Lilo-Beta", "fr.arouillard.lilo.debug": "Lilo-Debug"
    ]

    /// `~/Library/Application Support/<Lilo|Lilo-Beta|Lilo-Debug>` for the given bundle id, nil when the
    /// folder does not exist or the bundle id is this build's own (a build never imports from itself).
    static func supportDirectory(bundleId: String, home: URL, ownBundleId: String) -> URL? {
        guard bundleId != ownBundleId, let name = folderNames[bundleId] else { return nil }
        let url = home.appendingPathComponent("Library/Application Support/\(name)", isDirectory: true)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .some(.typeDirectory) else { return nil }
        return url
    }
}
