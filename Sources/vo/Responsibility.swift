import Darwin
import Dispatch
import Foundation
import MachO

// Private libSystem call. When set on the spawn attributes, the spawned child
// becomes its own TCC responsible process instead of inheriting the launching
// terminal's. There is no exec-based equivalent, which is why claiming vo's own
// identity requires spawning a child rather than re-imaging the current process.
// Resolved with dlsym at runtime rather than linked directly: if a future macOS
// drops or renames the symbol, that turns into a graceful fallback instead of a
// dyld abort at launch that would defeat the best-effort design.
private typealias SetDisclaimFn =
    @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

// Holds the disclaimed child's pid so the signal-forwarding handlers can reach
// it. Written once before the sources are resumed, then only read, so the
// unchecked access is safe.
nonisolated(unsafe) private var disclaimedChildPID: pid_t = 0

enum Responsibility {
    // Set on the spawned child so it does not spawn yet another copy.
    private static let guardKey = "VO_DISCLAIMED"

    /// Re-launch vo as its own responsible process so the Microphone / Speech /
    /// Audio Recording prompts attach to vo rather than the host terminal.
    ///
    /// On success this never returns: the launcher waits on the child and exits
    /// with its status. It returns (so the caller keeps running in-process under
    /// the terminal's identity) when already running as the disclaimed child, or
    /// when any step fails. Permission isolation is best-effort, never a gate on
    /// startup.
    static func reexecAsResponsibleProcess() {
        guard getenv(guardKey) == nil else { return }
        // A disclaimed process is its own responsible process, so it must carry the
        // usage descriptions itself. Only the release build embeds them (see
        // build.sh); re-launching a plain `swift build` binary would hit the mic
        // with no usage string and get killed, so leave such builds on the
        // terminal's identity instead. This guard is the expected path for dev
        // builds, so it stays silent.
        guard hasEmbeddedInfoPlist() else { return }
        guard let exePath = executablePath() else {
            warn("could not resolve its own path; continuing under the terminal's identity")
            return
        }

        // dlsym's RTLD_DEFAULT pseudo-handle (search every already-loaded image);
        // Darwin doesn't surface the macro to Swift, so spell out its value.
        // libSystem (which exports the symbol) is always loaded, so a nil result
        // means this macOS lacks it.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_spawnattrs_setdisclaim") else {
            warn("the responsibility API is unavailable on this macOS; continuing under the terminal's identity")
            return
        }
        let setDisclaim = unsafeBitCast(symbol, to: SetDisclaimFn.self)

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else {
            warn("could not initialize spawn attributes; continuing under the terminal's identity")
            return
        }
        defer { posix_spawnattr_destroy(&attr) }
        guard setDisclaim(&attr, 1) == 0 else {
            warn("could not disclaim responsibility; continuing under the terminal's identity")
            return
        }
        // posix_spawn hands the child the calling thread's signal mask and ignored
        // dispositions. This runs from async code, so the calling thread is a
        // dispatch worker with SIGTERM and friends blocked, and the child would start
        // with them blocked too. Then neither `kill <pid>` nor the launcher's
        // forwarding would ever land. Start the child from a clean mask and default
        // dispositions.
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var defaulted = sigset_t()
        sigfillset(&defaulted)
        guard posix_spawnattr_setsigmask(&attr, &emptyMask) == 0,
              posix_spawnattr_setsigdefault(&attr, &defaulted) == 0,
              posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) == 0
        else {
            warn("could not reset signal state for its helper process; continuing under the terminal's identity")
            return
        }

        let argv: [UnsafeMutablePointer<CChar>?] =
            CommandLine.arguments.map { strdup($0) } + [nil]
        let envp = environmentWithGuard()

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, exePath, nil, &attr, argv, envp)
        // posix_spawn copies argv/envp into the child, so the parent's duplicates
        // are dead after the call on either outcome.
        freeCStringArray(argv)
        freeCStringArray(envp)
        guard rc == 0 else {
            warn("could not claim its own permissions (\(String(cString: strerror(rc)))); continuing under the terminal's identity")
            return
        }

        // Keep the launcher alive to reap the child and report its status, but make
        // a kill aimed at this pid still reach the capturing child. SIGTERM/SIGQUIT
        // are not delivered to the process group by a terminal, so forward those so
        // `kill <pid>` / a process manager stops the child. SIGINT is left ignored,
        // not forwarded: a terminal Ctrl-C already reaches the child directly via
        // the shared process group, and a forwarded second SIGINT would trip the
        // child's repeat-Ctrl-C hard abort and skip its save prompt.
        //
        // The forwarders run through DispatchSource (handlers fire on a dispatch
        // queue, not in async-signal-unsafe handler context), mirroring how
        // Listen.swift handles SIGINT. DispatchSource requires the default
        // disposition be ignored first.
        disclaimedChildPID = pid
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        let forwarders: [DispatchSourceSignal] = [SIGTERM, SIGQUIT].map { sig in
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                if disclaimedChildPID > 0 { kill(disclaimedChildPID, sig) }
            }
            source.resume()
            return source
        }

        // Hold the sources past the blocking wait, or the optimizer could release
        // (and cancel) them while the launcher is parked in waitpid.
        withExtendedLifetime(forwarders) {
            var wstatus: Int32 = 0
            var reaped: pid_t = 0
            repeat {
                reaped = waitpid(pid, &wstatus, 0)
            } while reaped == -1 && errno == EINTR
            guard reaped != -1 else {
                // Couldn't reap the child, so its real status is unknown; don't
                // claim success.
                warn("lost track of its helper process (\(String(cString: strerror(errno)))); exit status unknown")
                exit(1)
            }

            if (wstatus & 0x7f) == 0 {
                exit((wstatus >> 8) & 0xff)
            }
            exit(128 + (wstatus & 0x7f))
        }
    }

    private static func hasEmbeddedInfoPlist() -> Bool {
        guard let header = _dyld_get_image_header(0) else { return false }
        var size: UInt = 0
        let section = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            getsectiondata($0, "__TEXT", "__info_plist", &size)
        }
        return section != nil && size > 0
    }

    private static func executablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
        // Resolve symlinks (Homebrew links vo into its bin) so the spawned path is
        // the real Mach-O whose embedded Info.plist + signature TCC keys on.
        if let resolved = realpath(buf, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func environmentWithGuard() -> [UnsafeMutablePointer<CChar>?] {
        var env: [UnsafeMutablePointer<CChar>?] = []
        var cursor = environ
        while let entry = cursor.pointee {
            env.append(strdup(entry))
            cursor = cursor.advanced(by: 1)
        }
        env.append(strdup("\(guardKey)=1"))
        env.append(nil)
        return env
    }

    private static func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for entry in array where entry != nil { free(entry) }
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("vo: \(message).\n".utf8))
    }
}
