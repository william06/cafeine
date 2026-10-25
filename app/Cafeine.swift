// Cafeine: menu bar icon for cafeine.sh.
//
// The app never changes the system itself. To start it runs the installed copy
// of the script with administrator privileges (macOS asks for the password),
// and to stop it creates the file the script watches for. It reads the state
// from the files the script leaves in /var/db/cafeine.

import AppKit
import SwiftUI

let stateDir = "/var/db/cafeine"
let script = "/usr/local/libexec/cafeine.sh"
let backstopPlist = "/Library/LaunchDaemons/com.cafeine.recover.plist"
let stopFile = "/tmp/cafeine-stop"

/// Reads a file of key=value lines.
func readKeys(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var keys: [String: String] = [:]
    for line in text.split(separator: "\n") {
        guard let equals = line.firstIndex(of: "=") else { continue }
        keys[String(line[..<equals])] = String(line[line.index(after: equals)...])
    }
    return keys
}

enum SessionState {
    case idle
    case active
    /// There is a journal but the process is gone: the backstop will fix it.
    case pending
}

@MainActor
final class Model: ObservableObject {
    @Published var state: SessionState = .idle
    @Published var end: Date?
    @Published var battery = ""
    @Published var onBattery = false
    @Published var heat = ""
    @Published var lowPower = false
    @Published var lidClosed = false
    @Published var scriptInstalled = false
    /// The installed copy can't handle "End now" from the app
    @Published var scriptOutdated = false
    @Published var backstopInstalled = false
    @Published var busy = false
    @Published var error: String?
    @Published var now = Date()
    // Duration picked in the panel (here rather than in @State: the Command
    // Line Tools don't ship the SwiftUI macro plugin)
    @Published var hours = 3
    @Published var minutes = 0
    private var clock: Timer?

    init() {
        refresh()
        clock = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        now = Date()
        scriptInstalled = FileManager.default.isExecutableFile(atPath: script)
        let installed = (try? String(contentsOfFile: script, encoding: .utf8)) ?? ""
        scriptOutdated = scriptInstalled && !installed.contains(stopFile)
        backstopInstalled = FileManager.default.fileExists(atPath: backstopPlist)

        let journal = readKeys(stateDir + "/journal")
        guard let pidText = journal["pid"], let pid = Int32(pidText) else {
            state = .idle
            end = nil
            return
        }
        // The process belongs to root: kill(pid, 0) gives EPERM if it exists and ESRCH if not.
        let alive = kill(pid, 0) == 0 || errno == EPERM
        state = alive ? .active : .pending
        if let text = journal["end"], let seconds = Double(text) {
            end = Date(timeIntervalSince1970: seconds)
        }

        let status = readKeys(stateDir + "/status")
        battery = status["battery"] ?? ""
        onBattery = status["on_battery"] == "1"
        heat = status["heat"] ?? ""
        lowPower = status["low_power"] == "1"
        lidClosed = status["lid_closed"] == "1"
    }

    var remaining: String {
        guard let end else { return "" }
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours):\(String(format: "%02d", minutes))" }
        if minutes > 0 { return "\(minutes) min" }
        return "\(seconds % 60) s"
    }

    func start(minutes: Int) {
        guard minutes > 0, !busy else { return }
        busy = true
        error = nil
        let command = "\(script) \(minutes) >/dev/null 2>&1 &"
        let source = """
            do shell script "\(command)" with prompt "Cafeine needs permission to keep your Mac awake." with administrator privileges
            """
        Task.detached {
            let result = runOsascript(source)
            await MainActor.run {
                self.busy = false
                if case .failed(let message) = result { self.error = message }
                self.refresh()
            }
        }
    }

    func stop() {
        error = nil
        if !FileManager.default.createFile(atPath: stopFile, contents: nil) {
            error = "Couldn't ask the session to end."
        }
    }
}

enum OsascriptResult {
    case ok
    case cancelled
    case failed(String)
}

func runOsascript(_ source: String) -> OsascriptResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", source]
    let stderr = Pipe()
    process.standardError = stderr
    process.standardOutput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return .failed("Couldn't run osascript: \(error.localizedDescription)")
    }
    process.waitUntilExit()
    if process.terminationStatus == 0 { return .ok }
    let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // -128: the user cancelled the password dialog
    if text.contains("-128") { return .cancelled }
    return .failed(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

struct Panel: View {
    @ObservedObject var model: Model

    private let presets: [(String, Int)] = [("30 min", 30), ("1 h", 60), ("3 h", 180), ("8 h", 480)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: model.state == .active ? "cup.and.saucer.fill" : "moon.zzz")
                Text("Cafeine").font(.headline)
            }

            if !model.scriptInstalled {
                Notice(text: "The script isn't installed. In the project folder: sudo ./cafeine.sh install")
            } else {
                if model.scriptOutdated {
                    Notice(text: "The installed script is outdated and can't be ended from here. In the project folder: sudo ./cafeine.sh install")
                }
                switch model.state {
                case .active: active
                case .pending:
                    Notice(text: "The session ended abruptly. The backstop will restore it within a minute.")
                case .idle: idle
                }
            }

            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                if !model.backstopInstalled {
                    Label("Backstop not installed", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 290)
        .onAppear { model.refresh() }
    }

    private var active: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.remaining)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
            if let end = model.end {
                Text("Awake until \(end.formatted(date: .omitted, time: .shortened))")
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                Row(name: "Battery", value: model.battery.isEmpty ? "—"
                    : "\(model.battery)%\(model.onBattery ? "" : " (charging)")")
                Row(name: "Heat", value: heatName(model.heat))
                Row(name: "Low Power", value: model.lowPower ? "On" : "Off")
                Row(name: "Lid", value: model.lidClosed ? "Closed" : "Open")
            }
            .font(.callout)
            Button(role: .destructive) { model.stop() } label: {
                Text("End now").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keep your Mac awake, even with the lid closed.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach(presets, id: \.1) { name, total in
                    Button(name) { model.start(minutes: total) }
                }
            }
            .disabled(model.busy)
            HStack {
                Stepper("\(model.hours) h", value: $model.hours, in: 0...72)
                Picker("", selection: $model.minutes) {
                    ForEach([0, 15, 30, 45], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
            }
            Button {
                model.start(minutes: model.hours * 60 + model.minutes)
            } label: {
                Text(model.busy ? "Waiting for permission…" : "Start").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.busy || model.hours * 60 + model.minutes == 0)
        }
    }

    private func heatName(_ heat: String) -> String {
        switch heat {
        case "high": return "High"
        case "critical": return "Critical"
        case "normal": return "Normal"
        default: return "—"
        }
    }
}

struct Row: View {
    let name: String
    let value: String
    var body: some View {
        GridRow {
            Text(name).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

struct Notice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize(horizontal: false, vertical: true)
    }
}

@main
struct CafeineApp: App {
    @StateObject private var model = Model()

    var body: some Scene {
        MenuBarExtra {
            Panel(model: model)
        } label: {
            if model.state == .active {
                Label(model.remaining, systemImage: "cup.and.saucer.fill").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "moon.zzz")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
