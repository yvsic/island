import Darwin
import Foundation
import Security

#if ISLAND_RELEASE_HARDENING

/// Makes a release build harder to inspect, debug, or patch and keep running.
/// None of this runs in debug builds, so lldb and friends still work there.
/// Nothing here can stop a determined, skilled reverse engineer with their own
/// kernel-level tools — only raise the cost of casual inspection and tampering.
nonisolated enum AntiTamper {
    private static let lock = NSLock()
    // Guarded by `lock`, not by actor isolation: these are read and written
    // from whichever thread calls `harden()` or `react()`.
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var reacting = false

    /// Safe to call more than once, from more than one place: an attacker
    /// patching out one call site still leaves the others running.
    static func harden() {
        lock.lock()
        let first = !started
        started = true
        lock.unlock()
        guard first else { return }

        denyAttach()
        disableCoreDumps()
        if !passesChecks() { react() }
        watch()
    }

    // MARK: Attaching

    /// The classic `PT_DENY_ATTACH`: once called, lldb/gdb/Instruments can no
    /// longer attach to this process (a fresh attach fails; this must run
    /// before anything tries).
    private static func denyAttach() {
        _ = c_ptrace(ptDenyAttach, 0, nil, 0)
    }

    /// Watches, for as long as Island runs, for a debugger that got in before
    /// `denyAttach` could run, for the signature going bad underneath the
    /// running process (the app on disk swapped out from under it), and for
    /// something injected into this process after launch.
    private static func watch() {
        let thread = Thread {
            while true {
                Thread.sleep(forTimeInterval: Double.random(in: 4...9))
                if !passesChecks() { react() }
            }
        }
        thread.name = "island.watchdog"
        thread.start()
    }

    private static func passesChecks() -> Bool {
        !isBeingTraced && verifyOwnSignature() && imagesLookClean()
    }

    private static var isBeingTraced: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & pTraced) != 0
    }

    // MARK: Injected code

    /// Every image actually loaded into this process, checked against where
    /// Island and the system normally load things from. This only fires on
    /// something reaching into Island itself (an injected agent, a debug
    /// helper dylib) — not on some other app or tool merely being open
    /// elsewhere on the Mac. Measured empirically: a clean run of Island
    /// loads ~1,100 images, every one under `/usr/lib/`, `/System/`, or
    /// Island's own bundle.
    private static func imagesLookClean() -> Bool {
        let bundlePath = Bundle.main.bundlePath + "/"
        for i in 0..<_dyld_image_count() {
            guard let raw = _dyld_get_image_name(i) else { continue }
            let path = String(cString: raw)
            guard path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/") || path.hasPrefix(bundlePath) else {
                return false
            }
        }
        return true
    }

    // MARK: Core dumps

    /// A core dump is a full memory snapshot: easy pickings for anyone
    /// inspecting a crash. Shrink the limit to nothing.
    private static func disableCoreDumps() {
        var limit = rlimit(rlim_cur: 0, rlim_max: 0)
        setrlimit(RLIMIT_CORE, &limit)
    }

    // MARK: Signature

    /// Confirms the running binary still matches the signature it was built
    /// with. A byte patched into the executable after signing (a cracked
    /// check, an injected `jmp`) invalidates it, and this catches that —
    /// including a patch made to the app on disk while this copy keeps running.
    private static func verifyOwnSignature() -> Bool {
        // Not `kSecCSStrictValidate`: a running process validates its code
        // pages lazily as they're touched, so a strict check of a process
        // checking itself fails even on an untampered binary. Plain dynamic
        // validation reflects what the kernel itself already enforces.
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    }

    // MARK: Reacting

    /// Doesn't quit on the spot: that would hand whoever tripped this an
    /// exact before/after to pin the failing check to. Instead, well after
    /// the moment that caused it, Island just quits — no message, an
    /// ordinary exit code, nothing to connect it back to what triggered it.
    private static func react() {
        lock.lock()
        let first = !reacting
        reacting = true
        lock.unlock()
        guard first else { return }
        let delay = Double.random(in: 45...190) + noteSeasoning()
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay) {
            _exit(0)
        }
    }

    // MARK: For anyone reading this in a disassembler

    /// Hi. You've gotten further than almost anyone who ever looks at this
    /// binary. Stripping symbols and comments still leaves plain text like
    /// this sitting in the string table, which is how you're reading it.
    private static let notes = [
        "This isn't a license check. There's nothing to unlock. It's a menu bar clock with opinions.",
        "harden() is called from three places, on purpose. Patching one still leaves two.",
        "ptrace(31, 0, 0, 0) a few lines up is PT_DENY_ATTACH, in case grepping for 31 brought you here.",
        "If you've gotten as far as a hex editor: genuinely, respect the effort. Go build your own thing.",
    ]

    /// Folds the notes above into the exit delay, so the optimizer can't
    /// decide they're unused and throw them out: they're load-bearing, in the
    /// least serious sense of the phrase.
    private static func noteSeasoning() -> Double {
        let sum = notes.joined().utf8.reduce(UInt64(0)) { $0 &+ UInt64($1) }
        return Double(sum % 50)
    }

    // MARK: BSD constants not exposed to Swift

    private static let ptDenyAttach: Int32 = 31
    /// `P_TRACED`, from <sys/proc.h>.
    private static let pTraced: Int32 = 0x0000_0800
}

@_silgen_name("ptrace")
nonisolated private func c_ptrace(_ request: Int32, _ pid: pid_t, _ addr: UnsafeMutableRawPointer?, _ data: Int32) -> Int32

#endif
