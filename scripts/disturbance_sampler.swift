// Runs a command and records, every INTERVAL ms, what it does to the desktop session it runs in, then prints a
// disturbance score: focus taken, Dock icons, windows shown, cursor and keyboard events not from the user, CPU and how
// late an interactive thread runs. Needs no Accessibility or Screen Recording grant: it reads the frontmost app,
// window owners and bounds (never titles), the cursor location and idle times, and process CPU times.
//
//   disturbance-sampler [--interval MS] [--label NAME] [--out FILE.jsonl] [--json] -- COMMAND [ARGS...]
//
// Built by `make test-disturbance` (swiftc), which is the command surface. A test host is a process whose bundle id
// ends in `.tests`; what its WebKit helpers use counts as the tests' own CPU.
import AppKit
import Darwin
import Foundation

struct Options {
    var intervalMs = 200
    var label = ""
    var out: String?
    var json = false
    var command: [String] = []
}

func parseOptions() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())[...]
    while let arg = args.popFirst() {
        switch arg {
        case "--interval": options.intervalMs = Int(args.popFirst() ?? "") ?? 200
        case "--label": options.label = args.popFirst() ?? ""
        case "--out": options.out = args.popFirst()
        case "--json": options.json = true
        case "--": options.command = Array(args); args.removeAll()
        default:
            FileHandle.standardError.write(Data("usage: disturbance-sampler [--interval MS] [--label NAME] [--out FILE] [--json] -- COMMAND...\n".utf8))
            exit(2)
        }
    }
    if options.command.isEmpty {
        FileHandle.standardError.write(Data("disturbance-sampler: no command after --\n".utf8))
        exit(2)
    }
    return options
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)

/// Fixed slice of CPU work: how long it takes tells how long a runnable interactive thread waits for a core.
@inline(never)
func spin() -> Double {
    let start = now()
    var x: UInt64 = 1
    for i in 0..<400_000 { x = x &* 6364136223846793005 &+ UInt64(i) }
    if x == 42 { print("") }
    return (now() - start) * 1000
}

final class Sampler {
    let options: Options
    let start = now()
    var out: FileHandle?

    // Host processes and what each test-owned process used last second.
    var hostBundle: [pid_t: Bool] = [:]
    var cpuByPid: [pid_t: UInt64] = [:]
    var lastScan = 0.0
    var hosts = 0, helpers = 0
    var testCores = 0.0, hostCores = 0.0

    var frontChanges = 0
    var hostActivations = 0
    var hostFrontSamples = 0
    var dockLaunches = 0
    var hostDockIcons = 0

    var visibleIDs = Set<Int>(), transparentIDs = Set<Int>(), hostWindowIDs = Set<Int>()
    var peakVisible = 0, peakTransparent = 0, peakHostWindows = 0
    var visibleSamples = 0
    var blockingIDs = Set<Int>()

    var lastCursor: CGPoint?
    var cursorJumps = 0
    var cursorPath = 0.0
    var syntheticSamples = 0
    var lastIdleHid = 0.0, lastIdleSession = 0.0

    var lastBusy: (UInt64, UInt64)?
    var cpuSamples: [Double] = []
    var peakLoad = 0.0
    var peakHosts = 0, peakHelpers = 0, peakTestCores = 0.0, peakHostCores = 0.0, testCoreSeconds = 0.0
    var lateness: [Double] = [], windowListMs: [Double] = [], spinMs: [Double] = []
    var samples = 0
    var baseSpin = 0.0

    init(_ options: Options) {
        self.options = options
        if let path = options.out {
            FileManager.default.createFile(atPath: path, contents: nil)
            out = FileHandle(forWritingAtPath: path)
        }
        baseSpin = (0..<5).map { _ in spin() }.min() ?? 0
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            frontChanges += 1
            if isTestHost(app.bundleIdentifier) { hostActivations += 1 }
            record(["event": "activate", "app": app.bundleIdentifier ?? app.localizedName ?? "?"])
        }
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  isTestHost(app.bundleIdentifier) else { return }
            // Only a regular app gets a Dock icon (and its bounce); a prohibited or accessory one never does.
            if app.activationPolicy == .regular { dockLaunches += 1 }
            record(["event": "launch", "host": true, "policy": app.activationPolicy.rawValue])
        }
    }

    func isTestHost(_ bundleID: String?) -> Bool { bundleID?.hasSuffix(".tests") ?? false }

    func record(_ fields: [String: Any]) {
        guard let out else { return }
        var line = fields
        line["t"] = ((now() - start) * 1000).rounded() / 1000
        line["wall"] = (Date().timeIntervalSince1970 * 1000).rounded() / 1000
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            out.write(data + Data("\n".utf8))
        }
    }

    func bundleIsHost(_ pid: pid_t) -> Bool {
        if let known = hostBundle[pid] { return known }
        let isHost = isTestHost(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
        hostBundle[pid] = isHost
        return isHost
    }

    /// CPU of test hosts and everything they are responsible for (WebContent, Networking, GPU), once a second.
    func scanProcesses() {
        let count = proc_listallpids(nil, 0)
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        let responsibleSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        let responsible = responsibleSymbol.map { unsafeBitCast($0, to: (@convention(c) (pid_t) -> pid_t).self) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var liveHosts = Set<pid_t>()
        for pid in pids.prefix(n) where pid > 1 {
            let length = proc_pidpath(pid, &path, UInt32(path.count))
            if length > 0, String(cString: path).hasSuffix("/Contents/MacOS/Lilo"), bundleIsHost(pid) { liveHosts.insert(pid) }
        }
        var total: UInt64 = 0, hostTotal: UInt64 = 0
        var newCPU: [pid_t: UInt64] = [:]
        var helperCount = 0
        for pid in pids.prefix(n) where pid > 1 {
            let owner = responsible?(pid) ?? pid
            guard liveHosts.contains(pid) || (owner != pid && liveHosts.contains(owner)) else { continue }
            if !liveHosts.contains(pid) { helperCount += 1 }
            var usage = rusage_info_v4()
            let ok = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } == 0
            }
            guard ok else { continue }
            let ticks = usage.ri_user_time &+ usage.ri_system_time
            newCPU[pid] = ticks
            if let before = cpuByPid[pid], ticks >= before {
                total &+= ticks - before
                if liveHosts.contains(pid) { hostTotal &+= ticks - before }
            }
        }
        let t = now()
        if lastScan > 0 {
            let seconds = Double(total) * Double(timebase.numer) / Double(timebase.denom) / 1e9
            testCores = seconds / (t - lastScan)
            hostCores = Double(hostTotal) * Double(timebase.numer) / Double(timebase.denom) / 1e9 / (t - lastScan)
        }
        lastScan = t
        cpuByPid = newCPU
        hosts = liveHosts.count
        helpers = helperCount
        peakHosts = max(peakHosts, hosts)
        peakHelpers = max(peakHelpers, helpers)
        peakTestCores = max(peakTestCores, testCores)
        peakHostCores = max(peakHostCores, hostCores)
        if lastScan > 0 { testCoreSeconds += testCores }
    }

    func systemBusy() -> Double? {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpus: natural_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpus, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        var busy: UInt64 = 0, all: UInt64 = 0
        for cpu in 0..<Int(cpus) {
            let base = cpu * Int(CPU_STATE_MAX)
            let user = UInt64(info[base + Int(CPU_STATE_USER)]), system = UInt64(info[base + Int(CPU_STATE_SYSTEM)])
            let nice = UInt64(info[base + Int(CPU_STATE_NICE)]), idle = UInt64(info[base + Int(CPU_STATE_IDLE)])
            busy += user + system + nice
            all += user + system + nice + idle
        }
        defer { lastBusy = (busy, all) }
        guard let last = lastBusy, all > last.1 else { return nil }
        return Double(busy - last.0) / Double(all - last.1)
    }

    func displays() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    func sample(late: Double) {
        samples += 1
        lateness.append(late * 1000)
        spinMs.append(spin())
        if now() - lastScan >= 1 { scanProcesses() }

        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier ?? "?"
        let hostFront = isTestHost(frontID)
        if hostFront { hostFrontSamples += 1 }

        let before = now()
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        windowListMs.append((now() - before) * 1000)
        let screens = displays()
        var visible = 0, transparent = 0, hostWindows = 0
        var shown: [[Int]] = [], ghosts: [[Int]] = []
        for window in list {
            guard let pid = window[kCGWindowOwnerPID as String] as? Int, bundleIsHost(pid_t(pid)),
                  let id = window[kCGWindowNumber as String] as? Int else { continue }
            let bounds = (window[kCGWindowBounds as String] as? [String: CGFloat]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } ?? .zero
            let alpha = (window[kCGWindowAlpha as String] as? Double) ?? 1
            let onscreen = (window[kCGWindowIsOnscreen as String] as? Bool) ?? false
            let layer = (window[kCGWindowLayer as String] as? Int) ?? 0
            guard layer >= 0, bounds.width > 1, bounds.height > 1 else { continue }
            hostWindows += 1
            hostWindowIDs.insert(id)
            guard onscreen, screens.contains(where: { $0.intersects(bounds) }) else { continue }
            if alpha > 0.01 { visible += 1; visibleIDs.insert(id); shown.append([id, pid, Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)]) } else { transparent += 1; transparentIDs.insert(id); ghosts.append([id, pid, Int(bounds.minX), Int(bounds.minY), Int(bounds.width), Int(bounds.height)]) }
        }
        // A transparent window still on screen takes the clicks aimed at what is under it, unless it ignores the mouse:
        // ask the window server whether it is the topmost window at its own centre.
        if let main = screens.first {
            for ghost in ghosts {
                let point = NSPoint(x: Double(ghost[2] + ghost[4] / 2), y: Double(main.height) - Double(ghost[3] + ghost[5] / 2))
                if NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0) == ghost[0] { blockingIDs.insert(ghost[0]) }
            }
        }
        peakVisible = max(peakVisible, visible)
        peakTransparent = max(peakTransparent, transparent)
        peakHostWindows = max(peakHostWindows, hostWindows)
        if visible > 0 { visibleSamples += 1 }

        // Posted events (a CGEvent at the HID tap) count in the session's idle time but never in the hardware's: a
        // session more recently active than the hardware means something other than the user moved the cursor or typed.
        let location = CGEvent(source: nil)?.location ?? .zero
        var jumped = false
        if let last = lastCursor {
            let distance = hypot(location.x - last.x, location.y - last.y)
            cursorPath += distance
            if distance > 40 { cursorJumps += 1; jumped = true }
        }
        lastCursor = location
        var synthetic = false
        for type: CGEventType in [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel] {
            let hid = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            let session = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
            if hid - session > 0.5, session < Double(options.intervalMs) / 1000 * 2 { synthetic = true }
        }
        if synthetic { syntheticSamples += 1 }

        if let busy = systemBusy() { cpuSamples.append(busy) }
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        peakLoad = max(peakLoad, load[0])

        record(["front": frontID, "hostFront": hostFront, "visible": visible, "transparent": transparent, "shown": shown, "ghosts": ghosts, "hostWindows": hostWindows,
                "cursor": [Int(location.x), Int(location.y)], "jump": jumped, "synthetic": synthetic,
                "busy": cpuSamples.last ?? 0, "load1": load[0], "hosts": hosts, "helpers": helpers, "testCores": testCores, "hostCores": hostCores,
                "lateMs": late * 1000, "spinMs": spinMs.last ?? 0, "windowListMs": windowListMs.last ?? 0])
    }

    func summary(exitCode: Int32, seconds: Double) -> [String: Any] {
        let busy = cpuSamples
        let score = 20 * hostActivations + 20 * dockLaunches + 5 * visibleIDs.count + 2 * transparentIDs.count
            + 20 * syntheticSamples + Int(Double(busy.filter { $0 >= 0.9 }.count) * Double(options.intervalMs) / 1000 / 10)
        return [
            "label": options.label, "exit": Int(exitCode), "seconds": (seconds * 10).rounded() / 10, "samples": samples,
            "focusActivations": hostActivations, "frontChanges": frontChanges, "hostFrontSamples": hostFrontSamples,
            "dockIcons": dockLaunches,
            "visibleWindows": visibleIDs.count, "peakVisible": peakVisible, "visibleSeconds": Double(visibleSamples) * Double(options.intervalMs) / 1000,
            "transparentOnScreen": transparentIDs.count, "transparentTakingClicks": blockingIDs.count, "peakTransparent": peakTransparent,
            "hostWindowsSeen": hostWindowIDs.count, "peakHostWindows": peakHostWindows,
            "cursorJumps": cursorJumps, "cursorPathPx": Int(cursorPath), "syntheticInputSamples": syntheticSamples,
            "cpuMean": (busy.reduce(0, +) / Double(max(busy.count, 1)) * 100).rounded(), "cpuP95": (percentile(busy, 0.95) * 100).rounded(),
            "cpuPeak": ((busy.max() ?? 0) * 100).rounded(), "secondsAbove90": Double(busy.filter { $0 >= 0.9 }.count) * Double(options.intervalMs) / 1000,
            "peakLoad1": (peakLoad * 10).rounded() / 10, "peakHosts": peakHosts, "peakHelpers": peakHelpers,
            "peakTestCores": (peakTestCores * 10).rounded() / 10, "peakHostCores": (peakHostCores * 10).rounded() / 10,
            "testCoreSeconds": testCoreSeconds.rounded(),
            "latenessP95Ms": (percentile(lateness, 0.95) * 10).rounded() / 10, "latenessMaxMs": ((lateness.max() ?? 0) * 10).rounded() / 10,
            "spinBaseMs": (baseSpin * 100).rounded() / 100, "spinP95Ms": (percentile(spinMs, 0.95) * 100).rounded() / 100,
            "spinMaxMs": ((spinMs.max() ?? 0) * 100).rounded() / 100,
            "windowListP95Ms": (percentile(windowListMs, 0.95) * 10).rounded() / 10, "windowListMaxMs": ((windowListMs.max() ?? 0) * 10).rounded() / 10,
            "score": score,
        ]
    }
}

let options = parseOptions()
signal(SIGINT, SIG_IGN)
let sampler = Sampler(options)
let child = Process()
child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
child.arguments = options.command
let started = now()
var expected = now()
var finished = false

func finish() {
    guard !finished else { return }
    finished = true
    let seconds = now() - started
    let result = sampler.summary(exitCode: child.terminationStatus, seconds: seconds)
    if options.json {
        let data = (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else {
        print("disturbance \(options.label.isEmpty ? "" : "[\(options.label)] ")score \(result["score"]!) in \(result["seconds"]!) s")
        for key in result.keys.sorted() where !["label", "score", "seconds"].contains(key) { print("  \(key): \(result[key]!)") }
    }
    exit(child.terminationStatus)
}

child.terminationHandler = { _ in DispatchQueue.main.async { finish() } }
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
termination.setEventHandler { child.terminate() }
termination.resume()
do { try child.run() } catch {
    FileHandle.standardError.write(Data("disturbance-sampler: \(error)\n".utf8))
    exit(127)
}
let interval = Double(options.intervalMs) / 1000
let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(1))
timer.setEventHandler {
    let t = now()
    sampler.sample(late: max(0, t - expected - interval))
    expected = t
}
timer.resume()
RunLoop.main.run()
