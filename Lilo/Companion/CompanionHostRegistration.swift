import Foundation

/// Registers the bundled `lilo-companion` host with the user's Chromium browsers: each browser
/// reads `<name>.json` from its native-messaging-hosts directory (`NativeMessagingHosts` on
/// macOS, `native-messaging-hosts` on Linux), and the file names the host executable and the
/// extension origins allowed to start it. The manifest template ships in the bundle with the
/// placeholders `@HOST_PATH@` and `@EXTENSION_ID@`; this fills them with the running app's host
/// path and the pinned companion extension id. Re-run at every launch, so an app move or update
/// repairs a stale registration. The Linux install path (policy JSON, postinst) is a later slice;
/// the template and this writer serve it when it lands.
enum CompanionHostRegistration {
    /// The pinned id of the companion extension (`manifest.json`'s `key`), the one origin the
    /// host manifest allows.
    static let extensionId = "pbjlfhpkfnmgnfmnljmmebmcmdgficod"

    /// The host executable's name in the app bundle (`PRODUCT_NAME` of the tool target).
    static let binaryName = "lilo-companion"

    /// The Chromium browsers that read user-level manifests on macOS, as `NativeMessaging` lists
    /// them. Only a browser whose user-data directory exists is registered: creating the
    /// directory for a browser the user does not have would leave an empty folder behind.
    private static let browserDirectories: [(userPath: String, manifestRelative: String)] = [
        ("Library/Application Support/Google/Chrome", "NativeMessagingHosts"),
        ("Library/Application Support/Google/Chrome Beta", "NativeMessagingHosts"),
        ("Library/Application Support/Google/Chrome Dev", "NativeMessagingHosts"),
        ("Library/Application Support/Google/Chrome Canary", "NativeMessagingHosts"),
        ("Library/Application Support/Chromium", "NativeMessagingHosts"),
        ("Library/Application Support/Microsoft Edge", "NativeMessagingHosts"),
        ("Library/Application Support/BraveSoftware/Brave-Browser", "NativeMessagingHosts"),
        ("Library/Application Support/Vivaldi", "NativeMessagingHosts"),
        ("Library/Application Support/Arc/User Data", "NativeMessagingHosts")
    ]

    /// Writes the manifest for every installed browser whose registration is missing or stale.
    /// An `LILO_APP_SUPPORT_DIR` override (tests, isolated runs) writes nothing: tests target
    /// the writer directly and an isolated run does not own the user's browsers.
    static func registerIfNeeded(home: String = NSHomeDirectory()) {
        guard ProcessInfo.processInfo.environment["LILO_APP_SUPPORT_DIR"] == nil else { return }
        let fileManager = FileManager.default
        guard let template = try? String(contentsOf: templateURL(), encoding: .utf8),
              let hostPath = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(binaryName).path,
              fileManager.isExecutableFile(atPath: hostPath) else { return }
        let manifest = manifest(template: template, hostPath: hostPath)
        for (userPath, manifestRelative) in browserDirectories {
            let dir = "\(home)/\(userPath)/\(manifestRelative)"
            guard fileManager.fileExists(atPath: "\(home)/\(userPath)") else { continue }
            let file = "\(dir)/\(CompanionProtocol.hostName).json"
            if (try? String(contentsOfFile: file, encoding: .utf8)) == manifest { continue }
            try? fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? manifest.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }

    /// The manifest the browser reads: the template's placeholders filled in, as the JSON
    /// Chromium parses.
    static func manifest(template: String, hostPath: String) -> String {
        template
            .replacingOccurrences(of: "@HOST_PATH@", with: hostPath)
            .replacingOccurrences(of: "@EXTENSION_ID@", with: extensionId)
    }

    /// The manifest template in the app bundle.
    static func templateURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appending(path: "Contents/Resources/companion-host/\(CompanionProtocol.hostName).json.in")
    }
}
