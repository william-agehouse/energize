import AppKit
import Foundation

// Energize — a menu bar switch for "keep running with the lid closed".
//
// The only thing that actually needs an administrator password is
// `pmset -a disablesleep 1`, which is the switch macOS uses to decide whether
// closing the lid puts the machine to sleep. Everything else here is either
// unprivileged, or done by a small root helper that this app starts at the same
// moment the password is typed.
//
// Why the helper exists: putting sleep *back* to normal also needs a password.
// If that had to be typed at the moment it happens, an unattended machine in a
// bag could never undo the switch. So the one privileged command also launches a
// root loop that watches two things — a heartbeat file this app keeps fresh, and
// a "revert" flag file — and puts sleep back on when either says to. No stored
// password, and by default nothing permanent is granted.
//
// There is one opt-in exception: `grant.sh`, which you run yourself once (the
// menu can open Terminal for you, but cannot run it), adds a
// rule letting exactly those two power commands run without a password. This app
// never installs that rule — it only asks whether it exists and takes the
// quieter route when it does.

// MARK: - Where the two flag files live

let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/energize")
let heartbeatPath = (stateDir as NSString).appendingPathComponent("heartbeat")
let revertPath = (stateDir as NSString).appendingPathComponent("revert")
let caffeinatePidPath = (stateDir as NSString).appendingPathComponent("caffeinate.pid")
/// The root helper rewrites this every couple of seconds while it is watching.
/// The menu reads it rather than trusting that starting the helper worked — an
/// earlier version assumed success and claimed a safety net that was not running.
let helperAlivePath = (stateDir as NSString).appendingPathComponent("helper-alive")
/// One word written by the helper just before it stands down, saying why.
let revertReasonPath = (stateDir as NSString).appendingPathComponent("revert-reason")
/// When the timer is due to fire, for the countdown in the menu. The helper
/// keeps its own copy baked in; this one is only for display.
let deadlinePath = (stateDir as NSString).appendingPathComponent("deadline")
/// Which arming is the current one. Written by the app each time the switch is
/// turned on, and never by a helper. A helper carries the number it was born
/// with and retires quietly if this file names a later one, so an older helper
/// left over from a previous arming cannot revert a lock it no longer owns.
let generationPath = (stateDir as NSString).appendingPathComponent("generation")

// Tunables — see README before changing these.
//
// How long the root helper waits after the last heartbeat before it decides this
// app is gone and puts sleep back on. Must be comfortably more than
// heartbeatIntervalSeconds so a busy machine doesn't trip it by accident.
let heartbeatGraceSeconds = 30
// How often this app touches the heartbeat file, and refreshes what the menu shows.
let heartbeatIntervalSeconds = 5.0
// How long to wait for the root helper to act on the revert flag before falling
// back to asking for a password. Only ever waited when a helper is actually
// running; without one we go straight to the password box.
let revertPatienceSeconds = 3.0
// How stale the helper's liveness file may get before we treat it as gone. The
// helper rewrites it every 2 seconds.
let helperAliveGraceSeconds = 10.0
// While the machine stays idle, how often to repeat the request to sleep the
// screen, in case something woke it without any input.
let screenOffRepeatSeconds = 60.0

// Choices offered for "switch the screen off after this long with no typing or
// trackpad use". Picked from the menu; 0 means never.
let screenOffChoices: [(label: String, seconds: Double)] = [
    ("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("Never", 0),
]
let screenOffPreferenceKey = "screenOffAfterIdleSeconds"

// How long to stay awake before standing down on its own. Chosen before arming,
// because the helper carries the deadline internally where nothing can extend it.
let timerChoices: [(label: String, seconds: Int)] = [
    ("30 minutes", 1800), ("1 hour", 3600), ("2 hours", 7200), ("No time limit", 0),
]
let timerPreferenceKey = "turnOffAfterSeconds"

// Battery level at which staying awake stops being a good idea.
let batteryFloorChoices: [(label: String, percent: Int)] = [
    ("10%", 10), ("15%", 15), ("25%", 25), ("Never", 0),
]
let batteryFloorPreferenceKey = "turnOffBelowBatteryPercent"

/// The helper writes one of these words and nothing else. Anything unrecognised
/// is ignored rather than shown — the folder is user-writable, so the menu should
/// not render text from it verbatim.
let revertReasons: [String: String] = [
    "asked":    "Switched off",
    "gone":     "Put itself back, the app stopped running",
    "timer":    "Put itself back, the time limit ran out",
    "battery":  "Put itself back, the battery got low",
    "lowpower": "Put itself back, Low Power Mode came on",
]

// MARK: - Reading the current state

func runCapturing(_ launchPath: String, _ args: [String]) -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: launchPath)
    proc.arguments = args
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do { try proc.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// The truth, straight from the system rather than from anything we remember.
func sleepIsDisabled() -> Bool {
    for line in runCapturing("/usr/bin/pmset", ["-g"]).split(separator: "\n")
    where line.contains("SleepDisabled") {
        // Read the value, not just any "1" anywhere on the line.
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
    }
    return false
}

func thermalStateText() -> String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal:  return "normal"
    case .fair:     return "warm"
    case .serious:  return "hot"
    case .critical: return "very hot"
    @unknown default: return "unknown"
    }
}

func machineIsHot() -> Bool {
    let state = ProcessInfo.processInfo.thermalState
    return state == .serious || state == .critical
}

/// Seconds since the last keypress, click or trackpad movement anywhere in the
/// session. A public reading — it needs no permission and no private framework.
func secondsSinceLastInput() -> Double {
    guard let anyEvent = CGEventType(rawValue: ~UInt32(0)) else { return 0 }
    return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
}

/// True when the laptop's own screen is the only one in use. That is the case
/// the screen-off behaviour exists for: a laptop on its own, lid shut, backlight
/// with nobody looking at it.
///
/// With an external display attached this must not fire, for two reasons.
/// Sleeping the displays is system-wide, so it would blank the monitor someone is
/// working on. And macOS already handles a closed lid properly in that setup —
/// it switches to clamshell mode by itself, with no help needed here.
///
/// The check has to be "is the built-in the only active display" rather than a
/// count, because in clamshell mode the built-in drops out of the list and an
/// external monitor is then the only one there.
func builtInIsOnlyDisplay() -> Bool {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count == 1 else { return false }
    var ids = [CGDirectDisplayID](repeating: 0, count: 1)
    guard CGGetActiveDisplayList(1, &ids, &count) == .success, count == 1 else { return false }
    return CGDisplayIsBuiltin(ids[0]) != 0
}

/// Switches the screen off the same way macOS does on a normal lid close. Needs
/// no administrator password, and any keypress brings it straight back.
func switchScreenOff() {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    proc.arguments = ["displaysleepnow"]
    try? proc.run()
}

func nowText() -> String {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm"
    return fmt.string(from: Date())
}

// MARK: - Asking for the password once, and starting the root helper

func appleScriptStringLiteral(_ text: String) -> String {
    var out = ""
    for ch in text {
        if ch == "\\" { out += "\\\\" }
        else if ch == "\"" { out += "\\\"" }
        else { out.append(ch) }
    }
    return "\"" + out + "\""
}

/// Shows the standard macOS password box and runs `command` as root.
/// Returns false if the password box was cancelled.
func runPrivileged(_ command: String) -> Bool {
    let script = "do shell script " + appleScriptStringLiteral(command)
        + " with administrator privileges"
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script]
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    do { try proc.run() } catch { return false }
    proc.waitUntilExit()
    return proc.terminationStatus == 0
}

/// True when the two power commands may run without a password — i.e. the rule
/// grant.sh installs is in place. Asks sudo itself rather than reading the file,
/// because the file is not readable by you and sudo is the thing that decides.
///
/// This used to run `sudo -n -l /usr/bin/pmset -a disablesleep 1` and trust the
/// exit code, which was wrong in a way that mattered: that form answers "is this
/// command permitted at all", not "is it permitted without a password". On any
/// Mac where you are an administrator it says yes to everything, `rm -rf`
/// included, so the app believed it was password-free on machines where it was
/// not — and then every attempt to switch on failed silently. So read the list
/// and look for the line that actually says NOPASSWD.
///
/// It is only used to decide which route to try first and what the menu says.
/// Both callers fall back to the password box if the quiet route fails, so a
/// wrong answer here costs a moment, not the feature.
func passwordFreeSwitching() -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    // -n: never prompt, just fail. -l: list what is permitted, run nothing.
    proc.arguments = ["-n", "-l"]
    let out = Pipe()
    proc.standardOutput = out
    proc.standardError = Pipe()
    do { try proc.run() } catch { return false }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0,
          let listing = String(data: data, encoding: .utf8) else { return false }

    return listing.split(separator: "\n").contains { line in
        line.contains("NOPASSWD") && line.contains("/usr/bin/pmset -a disablesleep 1")
    }
}

/// Runs sudo without ever prompting: it fails instead of asking. That is what
/// makes it safe to call speculatively, and it is the only way this app uses
/// sudo at all.
///
/// Note what is deliberately absent: nothing here writes to /etc/sudoers.d. The
/// optional rule is installed by `grant.sh`, which you run yourself, once, from
/// Terminal — so the privileged step is yours and is visible as plain shell you
/// can read before running. An app that quietly grants itself password-free root
/// is the thing a reviewer should object to, so it does not do that.
func runSudoWithoutPrompting(_ arguments: [String]) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    proc.arguments = ["-n"] + arguments
    proc.standardOutput = Pipe()
    proc.standardError = Pipe()
    do { try proc.run() } catch { return false }
    proc.waitUntilExit()
    return proc.terminationStatus == 0
}

/// The root loop. Note what it deliberately does NOT do: it never reads a command
/// out of a file, and never kills a process id it found in one. The only thing it
/// can be talked into is putting sleep *back to normal*, which is the safe
/// direction — so a flag file living in a user-writable folder grants nothing.
func guardianScript(deadline: Int, batteryFloor: Int, generation: Int,
                    pmsetPrefix: String) -> String {
    return """
    heartbeat='\(heartbeatPath)'
    revert='\(revertPath)'
    alive='\(helperAlivePath)'
    reason='\(revertReasonPath)'
    grace=\(heartbeatGraceSeconds)
    deadline=\(deadline)
    floor=\(batteryFloor)
    generation=\(generation)
    generation_file='\(generationPath)'
    started=$(/bin/date +%s)

    stand_down() {
      /bin/echo "$1" > "$reason"
      \(pmsetPrefix)/usr/bin/pmset -a disablesleep 0
      /bin/rm -f "$revert" "$alive"
      exit 0
    }

    while :; do
      now=$(/bin/date +%s)

      # Has the switch been armed again since this helper started? If so that
      # newer helper owns the lock. Retire without touching anything — reverting
      # here would cancel a lock somebody else is now managing.
      if [ -f "$generation_file" ]; then
        current=$(/usr/bin/head -c 32 "$generation_file" 2>/dev/null | /usr/bin/tr -dc '0-9')
        if [ -n "$current" ] && [ "$current" -gt "$generation" ]; then exit 0; fi
      fi

      /bin/echo $now > "$alive"

      # Asked to stop — either the switch was flicked or the machine got hot.
      if [ -f "$revert" ]; then stand_down asked; fi

      # The app has gone: quit, logged out, or crashed. Not checked for the
      # first `grace` seconds: the password box blocks the app's own timer while
      # it is open, so a slow typist would otherwise arm the lock and have it
      # undone immediately.
      if [ $((now - started)) -gt $grace ]; then
        stale=1
        if [ -f "$heartbeat" ]; then
          touched=$(/usr/bin/stat -f %m "$heartbeat" 2>/dev/null || /bin/echo 0)
          if [ $((now - touched)) -le $grace ]; then stale=0; fi
        fi
        if [ $stale -eq 1 ]; then stand_down gone; fi
      fi

      # Time limit.
      if [ $deadline -gt 0 ] && [ $now -ge $deadline ]; then stand_down timer; fi

      # Battery floor.
      if [ $floor -gt 0 ]; then
        pct=$(/usr/bin/pmset -g batt | /usr/bin/grep -oE '[0-9]+%' | /usr/bin/head -1 | /usr/bin/tr -d '%')
        if [ -n "$pct" ] && [ "$pct" -le $floor ]; then stand_down battery; fi
      fi

      # Low Power Mode means the machine has been told to conserve; step aside.
      if [ "$(/usr/bin/pmset -g | /usr/bin/awk '/lowpowermode/{print $2}')" = "1" ]; then
        stand_down lowpower
      fi

      /bin/sleep 2
    done
    """
}

/// Flip the switch and start the root loop in one privileged step, so there is
/// exactly one password prompt. The loop's text is carried as base64 straight
/// from this compiled binary — nothing on disk gets executed as root.
/// The watcher, wrapped so it survives the step that starts it. Used by both
/// routes; only `pmsetPrefix` and who runs it differ.
func startWatcherCommand(deadline: Int, batteryFloor: Int, generation: Int,
                         pmsetPrefix: String) -> String {
    let encoded = Data(guardianScript(deadline: deadline, batteryFloor: batteryFloor,
                                      generation: generation,
                                      pmsetPrefix: pmsetPrefix).utf8)
        .base64EncodedString()
    return "( /bin/echo \(encoded) | /usr/bin/base64 -D | /bin/sh >/dev/null 2>&1 & )"
        + " </dev/null >/dev/null 2>&1"
}

func armCommand(deadline: Int, batteryFloor: Int, generation: Int) -> String {
    let encoded = Data(guardianScript(deadline: deadline, batteryFloor: batteryFloor,
                                      generation: generation, pmsetPrefix: "").utf8)
        .base64EncodedString()
    // The subshell with every file handle detached is load-bearing. Running this
    // with administrator privileges goes through a different mechanism than a
    // plain shell, and a plainly backgrounded `nohup` pipeline is killed the
    // moment the privileged step returns — measured, not guessed. This shape
    // survives; handing the job to launchd is the other option that worked, if
    // this ever stops.
    return "/usr/bin/pmset -a disablesleep 1; "
        + "( /bin/echo \(encoded) | /usr/bin/base64 -D | /bin/sh >/dev/null 2>&1 & )"
        + " </dev/null >/dev/null 2>&1"
}

// MARK: - The explanation window

/// The text of the "How does this work?" window. Kept as data so the window code
/// stays about layout. Each entry is a heading and its paragraphs.
let infoSections: [(String, [String])] = [
    ("What it changes on your Mac", [
        "Three things, and every one of them reverses.",
        "It sets a single switch inside macOS that says \"do not go to sleep\", including when the lid closes. That switch is not saved into your settings. It lives in memory, so restarting the Mac always clears it.",
        "It runs a small system tool that stops the machine dropping into idle sleep on its own. It deliberately does not hold your screen on.",
        "While you are not touching the keyboard or trackpad, it asks the screen to switch off, the same thing macOS does when you close the lid normally.",
        "It adds no startup items, changes nothing in System Settings, installs nothing that needs a password later, and keeps its few small files in one folder inside your home directory.",
    ]),
    ("Why it only asks for a password once", [
        "Changing the sleep switch needs an administrator password. Turning it on can ask you, because you are sitting there. Turning it off again cannot, because a laptop in a bag has nobody to type it.",
        "So the same step that flips the switch also starts a small background watcher with the permission already granted. That watcher is what puts sleep back to normal, which is why switching off never asks for a password. Nothing is stored, and no lasting permission is left behind.",
        "If you would rather it never asked at all, choose \"Stop asking for my password\" in the menu. That does not grant anything by itself: it opens a Terminal window pointed at a short script called grant.sh, which ships inside the app, and then gets out of the way. You read the script, you type your own password, and you watch every line of what it does. The app has no way to install the rule on its own, which is the point.",
        "The rule it adds permits exactly two commands to run as root without a password: switching sleep off, and switching it back on. The arguments are written out in full and there are no wildcards, so nothing else is covered: not other pmset settings, not reading files, not any other program. It is granted to your account rather than to the app, because that is how sudo works; anything already running as you could use it. The worst that can be done with it is keeping the Mac awake, or letting it sleep. Choose \"Ask for my password again\" to undo it.",
    ]),
    ("When it stops on its own", [
        "The watcher checks every couple of seconds and puts sleep back to normal if any of these happen:",
        "•  You switch it off from the menu.",
        "•  The time limit runs out (one hour unless you change it).",
        "•  The battery falls below your chosen level (15% unless you change it).",
        "•  macOS reports the machine as hot.",
        "•  Low Power Mode is switched on.",
        "•  This app stops running: quit, logged out, or crashed.",
        "The menu tells you which one happened.",
    ]),
    ("Risks if you leave it unattended", [
        "Worth reading once.",
        "Heat. A laptop working hard inside a closed bag has nowhere to send its heat. It will get genuinely warm. The Mac's own protections do work. It slows itself down as it warms, and shuts down at a hard limit long before anything is damaged, so you cannot cook it into failure. But sustained heat does age a lithium battery faster, and a bag is the worst case for airflow. This app cuts the lock when macOS reports the machine as hot, which helps. It cannot cool it.",
        "One thing worth knowing: because a bag traps heat, the machine slows itself down, so the work takes longer and it stays hot for longer. The same job on a table finishes sooner and cooler.",
        "Battery. Staying awake uses power, and a bag means no charger. The battery floor exists for this. Leaving it on with no time limit and no floor is how people come back to a flat machine.",
        "It keeps working while locked. That is the point of it, and it was measured. It does mean whatever you started carries on with nobody watching.",
    ]),
    ("If something goes wrong", [
        "The worst realistic outcome is that the sleep switch stays on when you did not intend it to. That costs battery. It cannot damage anything, and it cannot lock you out of your Mac.",
        "Restarting always clears it. The switch lives in memory and does not survive a reboot, so a restart is the guaranteed fix if anything looks stuck.",
        "To check by hand, run this in Terminal. 1 means it is on, 0 means normal:",
        "     pmset -g | grep SleepDisabled",
        "To force it back by hand:",
        "     sudo pmset -a disablesleep 0",
        "If the watcher fails to start, the menu says so rather than pretending it is protected. It will read \"No safety net\", and the automatic stops above will not apply until you switch off and on again.",
        "If this app crashes or is force-quit, the watcher notices within about half a minute and puts sleep back to normal by itself.",
    ]),
    ("External displays", [
        "With a monitor attached, macOS already keeps the Mac running when you close the lid. That is clamshell mode, and it needs no help. This app leaves your screens completely alone in that situation, because switching the screen off would blank the monitor you are working on.",
    ]),
]

// MARK: - The menu bar app

final class Energize: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var caffeinate: Process?
    private var ticker: Timer?

    /// What we believe; `sleepIsDisabled()` is what's true. Reconciled every tick.
    private var armed = false
    /// Whether a root helper is genuinely watching, read from the liveness file
    /// it rewrites every two seconds. Deliberately not a flag we set ourselves:
    /// the previous version set it on a successful password entry and so claimed
    /// a safety net even when the helper had died on startup.
    private var hasSafetyNet: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: helperAlivePath),
              let lastWritten = attributes[.modificationDate] as? Date
        else { return false }
        return Date().timeIntervalSince(lastWritten) <= helperAliveGraceSeconds
    }
    /// When the screen was last asked to sleep, so the request can be repeated
    /// while the machine stays idle without being sent every few seconds.
    private var lastScreenOffRequest: Date?

    /// Minutes to stay awake before standing down. 0 = no limit.
    private var turnOffAfter: Int {
        get { (UserDefaults.standard.object(forKey: timerPreferenceKey) as? Int) ?? 3600 }
        set { UserDefaults.standard.set(newValue, forKey: timerPreferenceKey) }
    }

    /// Battery percentage at which to stand down. 0 = never.
    private var batteryFloor: Int {
        get { (UserDefaults.standard.object(forKey: batteryFloorPreferenceKey) as? Int) ?? 15 }
        set { UserDefaults.standard.set(newValue, forKey: batteryFloorPreferenceKey) }
    }

    /// When the time limit is due, for the countdown. Display only — the helper
    /// carries its own copy, so editing this file cannot extend the lock.
    private var deadline: Date? {
        guard let raw = try? String(contentsOfFile: deadlinePath, encoding: .utf8),
              let epoch = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              epoch > 0
        else { return nil }
        return Date(timeIntervalSince1970: epoch)
    }

    private func timeLeftText() -> String? {
        guard armed, let deadline else { return nil }
        let left = Int(deadline.timeIntervalSinceNow)
        guard left > 0 else { return nil }
        let hours = left / 3600, minutes = (left % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(max(minutes, 1))m"
    }

    /// Reads and clears the helper's one-word explanation. Unknown words are
    /// dropped rather than displayed.
    private func consumeRevertReason() -> String? {
        guard let raw = try? String(contentsOfFile: revertReasonPath, encoding: .utf8)
        else { return nil }
        try? FileManager.default.removeItem(atPath: revertReasonPath)
        return revertReasons[raw.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    /// How long with no input before the screen goes off, while armed. 0 = never.
    private var screenOffAfterIdle: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: screenOffPreferenceKey)
            return (stored as? Double) ?? 120
        }
        set { UserDefaults.standard.set(newValue, forKey: screenOffPreferenceKey) }
    }
    /// A one-line explanation shown in the menu after something happened by itself.
    private var note: String?
    /// Kept alive between openings so the window reopens where it was left.
    private var infoWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(
            atPath: stateDir, withIntermediateDirectories: true)

        // Clear leftovers from a previous run that ended badly.
        try? FileManager.default.removeItem(atPath: revertPath)
        killStaleCaffeinate()

        // variableLength, not squareLength: a square item clips the countdown
        // text to about one character.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = menu

        armed = sleepIsDisabled()
        if armed {
            // Someone turned this on outside the app — most likely by hand in a
            // terminal. Adopt it so the switch reads honestly, but say so: there
            // is no root helper watching, so the automatic safeties are not live.
            note = "Turned on outside this app, no automatic safety net"
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification, object: nil)

        ticker = Timer.scheduledTimer(withTimeInterval: heartbeatIntervalSeconds,
                                      repeats: true) { [weak self] _ in self?.tick() }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopCaffeinate()
        // Ask the root helper to put sleep back now, rather than making it wait
        // out the heartbeat grace period.
        if armed { FileManager.default.createFile(atPath: revertPath, contents: nil) }
    }

    // MARK: Heartbeat and reconciliation

    private func tick() {
        if armed { touchHeartbeat() }
        if armed { manageScreen() }

        // If the system disagrees with us, the system wins.
        let actuallyDisabled = sleepIsDisabled()
        if actuallyDisabled != armed {
            armed = actuallyDisabled
            if !actuallyDisabled {
                // The helper leaves one word behind saying why it stood down.
                note = consumeRevertReason() ?? "Put itself back to normal at \(nowText())"
                stopCaffeinate()
                try? FileManager.default.removeItem(atPath: deadlinePath)
            }
        }
        refresh()
    }

    /// While armed, put the screen to sleep once you have stopped touching the
    /// machine. This is what stops a closed laptop cooking itself: the setting
    /// that keeps it running does nothing about the backlight, and many people
    /// have their own screen-off timer set to never.
    private func manageScreen() {
        let limit = screenOffAfterIdle
        guard limit > 0 else { return }

        // Never touch the displays when a monitor is attached — see
        // builtInIsOnlyDisplay().
        guard builtInIsOnlyDisplay() else {
            lastScreenOffRequest = nil
            return
        }

        guard secondsSinceLastInput() >= limit else {
            // Back at the keyboard. Next quiet spell starts fresh.
            lastScreenOffRequest = nil
            return
        }

        // Still idle, so keep asking now and again rather than only once. A
        // notification can wake the display with no input at all — macOS lets
        // them request it — and a single request would leave the screen lit for
        // the rest of the time in the bag, which is the whole problem.
        if let last = lastScreenOffRequest,
           Date().timeIntervalSince(last) < screenOffRepeatSeconds { return }
        switchScreenOff()
        lastScreenOffRequest = Date()
    }

    private func touchHeartbeat() {
        let fm = FileManager.default
        if fm.fileExists(atPath: heartbeatPath) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: heartbeatPath)
        } else {
            fm.createFile(atPath: heartbeatPath, contents: nil)
        }
    }

    // MARK: Turning it on and off

    private func arm() {
        lastScreenOffRequest = nil
        try? FileManager.default.removeItem(atPath: revertPath)
        // Drop any liveness file left by a helper that is already gone, so a
        // stale one can't read as a working safety net.
        try? FileManager.default.removeItem(atPath: helperAlivePath)
        try? FileManager.default.removeItem(atPath: revertReasonPath)
        touchHeartbeat()   // so the helper sees us alive the moment it starts

        let limit = turnOffAfter
        let now = Int(Date().timeIntervalSince1970)
        let dueAt = limit > 0 ? now + limit : 0
        try? String(dueAt).write(toFile: deadlinePath, atomically: true, encoding: .utf8)
        // Claim this arming, so any helper still running from an earlier one
        // stands aside instead of reverting our lock.
        try? String(now).write(toFile: generationPath, atomically: true, encoding: .utf8)

        // Two routes to the same place. If you have run grant.sh, the switch can
        // be flipped straight away and the watcher runs as an ordinary process
        // that uses the same permission for its one privileged call — no dialog
        // at all. Otherwise fall back to asking, and to a watcher running as root.
        var started = false
        var quietRouteFailed = false
        if passwordFreeSwitching() {
            started = runSudoWithoutPrompting(["/usr/bin/pmset", "-a", "disablesleep", "1"])
                && runShell(startWatcherCommand(deadline: dueAt, batteryFloor: batteryFloor,
                                                generation: now,
                                                pmsetPrefix: "/usr/bin/sudo -n "))
            quietRouteFailed = !started
        }
        // Ask, either because there is no rule or because the quiet route did not
        // work after all. Better one unexpected password box than a switch that
        // does nothing.
        if !started {
            started = runPrivileged(armCommand(deadline: dueAt, batteryFloor: batteryFloor,
                                               generation: now))
        }

        if started {
            // Typing the password may have taken a while, and the timer below was
            // blocked throughout. Refresh the heartbeat before the helper's grace
            // period runs out.
            touchHeartbeat()
            armed = true
            note = nil
            startCaffeinate()
            // The helper needs a moment to write its first liveness line; check
            // back so the menu shows what really happened, and say so if the
            // helper failed to start.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self else { return }
                if !self.hasSafetyNet {
                    self.note = "Armed, but the safety net failed to start"
                }
                self.refresh()
            }
        } else {
            note = quietRouteFailed ? "Could not switch it on"
                                    : "Password cancelled, nothing changed"
            try? FileManager.default.removeItem(atPath: deadlinePath)
        }
        refresh()
    }

    /// Runs a shell command and waits for it. Used for the parts that need no
    /// elevation at all.
    private func runShell(_ command: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", command]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private func disarm(reason: String?) {
        let helperWasWatching = hasSafetyNet
        stopCaffeinate()
        note = reason

        guard helperWasWatching else {
            // Nothing is watching — the lock was set by hand in a terminal — so
            // waiting on the flag file would just be dead time before the
            // password box. Ask straight away.
            promptToRestoreSleep()
            return
        }

        FileManager.default.createFile(atPath: revertPath, contents: nil)
        refresh()

        // The helper polls every two seconds. Give it a moment, then check the
        // system rather than assuming it worked.
        DispatchQueue.main.asyncAfter(deadline: .now() + revertPatienceSeconds) { [weak self] in
            guard let self else { return }
            if sleepIsDisabled() {
                self.promptToRestoreSleep()
            } else {
                self.armed = false
                self.refresh()
            }
        }
    }

    /// Last resort: put sleep back with a password prompt, for a lock no helper
    /// is watching.
    private func promptToRestoreSleep() {
        try? FileManager.default.removeItem(atPath: revertPath)
        var restored = passwordFreeSwitching()
            && runSudoWithoutPrompting(["/usr/bin/pmset", "-a", "disablesleep", "0"])
        if !restored {
            restored = runPrivileged("/usr/bin/pmset -a disablesleep 0")
        }
        if restored {
            armed = false
            // Leave `note` as the caller set it. Clearing it here used to throw
            // away the reason — "the machine got hot" was the one that mattered.
        } else {
            note = "Still on, the password box was cancelled"
        }
        refresh()
    }

    @objc private func toggle() {
        if armed { disarm(reason: nil) } else { arm() }
    }

    /// Puts a root helper behind a lock that was set by hand, so the heat and
    /// revert-on-quit safeties start applying to it.
    @objc private func adoptLock() { arm() }

    // MARK: caffeinate — blocks plain idle sleep, which is a separate setting

    private func startCaffeinate() {
        stopCaffeinate()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        // Deliberately no -d and no -u. Both of those hold the *screen* on, which
        // is the thing that heats a closed laptop up. We only want the machine
        // itself kept from sleeping: -i idle, -m disk, -s while on mains power.
        proc.arguments = ["-ims"]
        do { try proc.run() } catch { return }
        caffeinate = proc
        try? String(proc.processIdentifier).write(
            toFile: caffeinatePidPath, atomically: true, encoding: .utf8)
    }

    private func stopCaffeinate() {
        caffeinate?.terminate()
        caffeinate = nil
        try? FileManager.default.removeItem(atPath: caffeinatePidPath)
    }

    /// Only ever aimed at a caffeinate we started ourselves, and only after
    /// checking that the process really is one — a recycled process id is not
    /// going to get killed by mistake.
    private func killStaleCaffeinate() {
        guard let text = try? String(contentsOfFile: caffeinatePidPath, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }
        let name = runCapturing("/bin/ps", ["-p", String(pid), "-o", "comm="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("caffeinate") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(atPath: caffeinatePidPath)
    }

    // MARK: Heat safety net

    @objc private func thermalStateChanged() {
        if armed && machineIsHot() {
            disarm(reason: "Turned itself off at \(nowText()), machine got \(thermalStateText())")
        }
        refresh()
    }

    // MARK: Menu

    /// The action row, with a red bolt after the words so the eye lands on the
    /// one item here that actually does something. Built as an attributed string
    /// because a menu item's own image would sit to the left of the text.
    private func energizeTitle() -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let title = NSMutableAttributedString(string: "Energize my MacBook ",
                                              attributes: [.font: font])
        // Sized to sit with the letters rather than tower over them. The glyph
        // renders taller than its point size, so this is well under the font's.
        let sizing = NSImage.SymbolConfiguration(pointSize: font.pointSize * 0.72, weight: .bold)
        let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        if let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(sizing.applying(red)) {
            let attachment = NSTextAttachment()
            attachment.image = bolt
            // Centre the glyph on the text rather than the baseline. An
            // attachment's y offset positions its *bottom* relative to the
            // baseline, and the glyph is taller than the letters, so resting it
            // on the baseline leaves it riding high. Line the middle of the glyph
            // up with the middle of a capital letter instead.
            attachment.bounds = CGRect(x: 0,
                                       y: (font.capHeight - bolt.size.height) / 2,
                                       width: bolt.size.width, height: bolt.size.height)
            title.append(NSAttributedString(attachment: attachment))
        }
        return title
    }

    private func refresh() {
        if let button = statusItem.button {
            // Same bolt in both states so the shape is recognisable at a glance:
            // hollow and monochrome when sleep is normal, solid red when armed.
            // Nothing moon-shaped, which on this menu bar reads as Do Not Disturb.
            let symbol = armed ? "bolt.fill" : "bolt"
            if var image = NSImage(systemSymbolName: symbol, accessibilityDescription:
                                    armed ? "Staying awake" : "Sleeping normally") {
                if armed {
                    // A template image is forced to the menu bar's own colour, so
                    // the red has to come from a palette configuration instead.
                    let red = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
                    image = image.withSymbolConfiguration(red) ?? image
                    image.isTemplate = false
                } else {
                    image.isTemplate = true
                }
                button.image = image
            }
            if let left = timeLeftText() {
                button.title = "  " + left
                button.imagePosition = .imageLeading
            } else {
                button.title = ""
                button.imagePosition = .imageOnly
            }
            button.toolTip = armed
                ? "Lid can be closed, the Mac will keep working"
                : "Closing the lid will put the Mac to sleep"
        }

        menu.removeAllItems()

        var headingText = armed ? "Keeps working with the lid closed"
                                : "Sleeps when the lid closes"
        if let left = timeLeftText() { headingText += ", \(left) left" }
        let heading = NSMenuItem(title: headingText, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())

        let switchItem = NSMenuItem(
            title: armed ? "Let it sleep again" : "Energize my MacBook",
            action: #selector(toggle), keyEquivalent: "")
        switchItem.target = self
        if !armed { switchItem.attributedTitle = energizeTitle() }
        menu.addItem(switchItem)

        if armed && !hasSafetyNet {
            let adopt = NSMenuItem(title: "Add the safety net (asks for password)",
                                   action: #selector(adoptLock), keyEquivalent: "")
            adopt.target = self
            menu.addItem(adopt)
        }

        if let note {
            menu.addItem(.separator())
            let noteItem = NSMenuItem(title: note, action: nil, keyEquivalent: "")
            noteItem.isEnabled = false
            menu.addItem(noteItem)
        }

        let screenMenu = NSMenu()
        for choice in screenOffChoices {
            let item = NSMenuItem(title: choice.label, action: #selector(pickScreenOffDelay(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.seconds
            item.state = (choice.seconds == screenOffAfterIdle) ? .on : .off
            screenMenu.addItem(item)
        }
        let screenItem = NSMenuItem(title: "Screen off when idle for", action: nil, keyEquivalent: "")
        screenItem.submenu = screenMenu
        menu.addItem(screenItem)

        let timerMenu = NSMenu()
        for choice in timerChoices {
            let item = NSMenuItem(title: choice.label, action: #selector(pickTimer(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.seconds
            item.state = (choice.seconds == turnOffAfter) ? .on : .off
            // Changing this mid-session would mean asking for the password again,
            // because the helper carries the deadline internally.
            item.isEnabled = !armed
            timerMenu.addItem(item)
        }
        let timerItem = NSMenuItem(title: armed ? "Time limit (set before arming)"
                                                : "Turn off after",
                                   action: nil, keyEquivalent: "")
        timerItem.submenu = timerMenu
        menu.addItem(timerItem)

        let batteryMenu = NSMenu()
        for choice in batteryFloorChoices {
            let item = NSMenuItem(title: choice.label, action: #selector(pickBatteryFloor(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.percent
            item.state = (choice.percent == batteryFloor) ? .on : .off
            item.isEnabled = !armed
            batteryMenu.addItem(item)
        }
        let batteryItem = NSMenuItem(title: armed ? "Battery floor (set before arming)"
                                                  : "Turn off below battery",
                                     action: nil, keyEquivalent: "")
        batteryItem.submenu = batteryMenu
        menu.addItem(batteryItem)

        menu.addItem(.separator())
        var status = [builtInIsOnlyDisplay() ? "" : "External display, screen left alone",
                      "Temperature: \(thermalStateText())",
                      passwordFreeSwitching() ? "Password not needed" : ""]
        if hasSafetyNet {
            status += ["Idle sleep also blocked",
                       "Turns itself off if it gets hot",
                       "Turns itself off if the battery gets low",
                       "Stands aside for Low Power Mode"]
        } else if armed {
            status.append("No safety net, switched on outside this app")
        } else {
            // Previously this said "No automatic safety net" whenever nothing was
            // armed, which reads like a setting you forgot to enable rather than
            // simply nothing running yet.
            status.append("Safeties switch on together with it")
        }
        for line in status where !line.isEmpty {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if hasSafetyNet {
            let warning = NSMenuItem(
                title: "Quitting here lets it sleep again", action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())
        let passwordItem: NSMenuItem
        if passwordFreeSwitching() {
            passwordItem = NSMenuItem(title: "Ask for my password again",
                                      action: #selector(startAskingForPassword), keyEquivalent: "")
        } else {
            passwordItem = NSMenuItem(title: "Stop asking for my password\u{2026}",
                                      action: #selector(stopAskingForPassword), keyEquivalent: "")
        }
        passwordItem.target = self
        menu.addItem(passwordItem)

        let info = NSMenuItem(title: "How does this work?", action: #selector(showInfo),
                              keyEquivalent: "")
        info.target = self
        menu.addItem(info)

        let quit = NSMenuItem(title: "Quit Energize", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func pickTimer(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        turnOffAfter = seconds
        refresh()
    }

    @objc private func pickBatteryFloor(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        batteryFloor = percent
        refresh()
    }

    @objc private func pickScreenOffDelay(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        screenOffAfterIdle = seconds
        lastScreenOffRequest = nil
        refresh()
    }

    // MARK: The explanation window

    private func infoAttributedText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let headingFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 12.5)
        let codeFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 2.5
        bodyStyle.paragraphSpacing = 9

        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacing = 5
        headingStyle.paragraphSpacingBefore = 18

        for (index, section) in infoSections.enumerated() {
            let style = headingStyle.mutableCopy() as! NSMutableParagraphStyle
            if index == 0 { style.paragraphSpacingBefore = 0 }
            out.append(NSAttributedString(string: section.0 + "\n", attributes: [
                .font: headingFont, .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style]))
            for paragraph in section.1 {
                // Indented lines are commands, shown in a fixed-width face.
                let isCommand = paragraph.hasPrefix("     ")
                out.append(NSAttributedString(string: paragraph + "\n", attributes: [
                    .font: isCommand ? codeFont : bodyFont,
                    .foregroundColor: isCommand ? NSColor.secondaryLabelColor
                                                : NSColor.labelColor,
                    .paragraphStyle: bodyStyle]))
            }
        }
        return out
    }

    @objc private func showInfo() {
        if infoWindow == nil {
            let frame = NSRect(x: 0, y: 0, width: 580, height: 640)
            let window = NSWindow(contentRect: frame,
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "How Energize works"
            // Without this, closing the window would destroy it and reopening
            // would land on freed memory.
            window.isReleasedWhenClosed = false
            window.center()

            let textView = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
            textView.isEditable = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 24, height: 22)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textStorage?.setAttributedString(infoAttributedText())

            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: frame.size))
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.autoresizingMask = [.width, .height]
            scroll.documentView = textView
            window.contentView = scroll
            infoWindow = window
        }
        // A menu bar app has no Dock icon, so it has to be brought to the front
        // deliberately or the window opens behind whatever you were reading.
        NSApp.activate(ignoringOtherApps: true)
        infoWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: The optional grant

    /// Where the bundled grant script lives, if it is there at all.
    private var grantScriptPath: String? {
        return Bundle.main.path(forResource: "grant", ofType: "sh")
    }

    /// Wraps a path for the shell. Bundle paths are usually tame, but an app
    /// folder can be renamed to anything.
    private func shellQuoted(_ path: String) -> String {
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Opens Terminal with the grant script, and puts the command on the
    /// clipboard as a fallback.
    ///
    /// Note what this does not do: it does not run the script, and the app never
    /// writes to /etc/sudoers.d itself. It has no privileges to hand out and asks
    /// for none. You read the script, you type your own password, and you can see
    /// every line of what happens in a window the app does not control. An app
    /// that quietly grants itself password-free root is the thing a reviewer
    /// should object to, so this one cannot.
    private func openGrantInTerminal(remove: Bool) {
        guard let script = grantScriptPath else {
            note = "grant.sh is missing from the app bundle"
            refresh()
            return
        }

        let command = "bash " + shellQuoted(script) + (remove ? " --remove" : "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)

        // A .command file opens in Terminal on a double-click, and `open` does
        // the same thing. Writing one lets the removal carry its flag, which a
        // plain `open -a Terminal <script>` cannot do. It is one readable line.
        let launcher = URL(fileURLWithPath: (stateDir as NSString).appendingPathComponent(
            remove ? "undo-grant.command" : "grant.command"))
        let body = "#!/bin/bash\n" + command + "\n"
        do {
            try body.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: launcher.path)
        } catch {
            note = "Command copied, paste it into Terminal"
            refresh()
            return
        }

        NSWorkspace.shared.open(
            [launcher],
            withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil)

        note = remove ? "Terminal opened, it will ask for your password once"
                      : "Terminal opened. Read it, then type your password"
        refresh()
    }

    @objc private func stopAskingForPassword() { openGrantInTerminal(remove: false) }
    @objc private func startAskingForPassword() { openGrantInTerminal(remove: true) }

    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

let application = NSApplication.shared
let delegate = Energize()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
