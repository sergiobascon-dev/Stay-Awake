import Foundation
import Security
import Darwin

/// An explicit compile-time channel for source built on this Mac. Distribution
/// builds never select it via preferences, Info.plist or environment variables.
enum LocalDevelopmentSigning {
    static func requirement(team: String, hash: Data) throws -> String {
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              hash.count == 20 else {
            throw LeaseFailure(message: "Invalid local-development code identity")
        }
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        // Both peers run the SAME executable. A different build, including one
        // signed with the same locally available key, has a different cdhash.
        return "anchor apple generic and identifier \"local.insomnialocal.app\" and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[field.1.2.840.113635.100.6.1.12] exists and certificate leaf[subject.OU] = \"\(team)\" and cdhash H\"\(hex)\""
    }

    static func validateHardening(flags: UInt32, entitlements: [String: Any]) throws {
        guard flags & SecCodeSignatureFlags.runtime.rawValue != 0, entitlements.isEmpty else {
            throw LeaseFailure(message: "Local privileged builds require Hardened Runtime and no entitlements")
        }
    }
}

enum LocalDevelopmentInstallation {
    // /Applications is writable by the admin group. Use a root-owned tree
    // with protected ancestors instead, so the bundle cannot be replaced by
    // renaming its parent without a fresh administrator authorization.
    static let bundle = URL(fileURLWithPath: "/Library/Application Support/InsomniaSafeLocal/Stay Awake.app", isDirectory: true)

    static func validate(bundle candidate: URL) throws {
        guard candidate.standardizedFileURL == bundle else {
            throw LeaseFailure(message: "Install the locally built package using macOS Installer before enabling power mode")
        }
        try validateTree(bundle: bundle, expectedOwner: 0, checkAncestors: true)
    }

    /// Owner injection is only for in-process filesystem tests. Production
    /// always checks uid 0 at the constant path above, never an RPC path.
    static func validateTree(bundle: URL, expectedOwner: uid_t, checkAncestors: Bool) throws {
        if checkAncestors {
            var ancestor = bundle.deletingLastPathComponent()
            while true {
                try validateObject(ancestor, expectedOwner: expectedOwner, directory: true)
                if ancestor.path == "/" { break }
                ancestor.deleteLastPathComponent()
            }
        }
        try validateObject(bundle, expectedOwner: expectedOwner, directory: true)
        var traversalFailure: Error?
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil,
            errorHandler: { _, error in traversalFailure = error; return false }) else {
            throw LeaseFailure(message: "Cannot inspect installed application")
        }
        for case let url as URL in enumerator {
            try validateObject(url, expectedOwner: expectedOwner, directory: false)
        }
        if let traversalFailure { throw traversalFailure }
    }

    private static func validateObject(_ url: URL, expectedOwner: uid_t, directory: Bool) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0,
              st.st_uid == expectedOwner, st.st_mode & 0o022 == 0,
              st.st_mode & 0o6000 == 0,
              (st.st_mode & S_IFMT == S_IFDIR || (!directory && st.st_mode & S_IFMT == S_IFREG)),
              (st.st_mode & S_IFMT == S_IFDIR || st.st_nlink == 1) else {
            throw LeaseFailure(message: "Unprotected object in local installation: \(url.path)")
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw LeaseFailure(message: "Cannot inspect installation permissions") }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else {
            throw LeaseFailure(message: "Installation changed during inspection")
        }
        errno = 0
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw LeaseFailure(message: "Cannot inspect installation ACL")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        guard acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 else {
            throw LeaseFailure(message: "Extended ACL in local installation")
        }
    }
}
