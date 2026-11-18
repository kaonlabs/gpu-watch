import Darwin
import Foundation

enum GPUState: String, CaseIterable, Decodable, Sendable {
    case idle, busy, unknown
}

struct GPUCard: Decodable, Identifiable, Sendable {
    let index: Int
    let utilization: Int?
    let state: GPUState
    let owners: [String?]

    var id: Int { index }
    var percent: String { utilization.map { "\($0)%" } ?? "–" }

    var ownerBadge: String {
        switch state {
        case .idle: "Idle"
        case .unknown: "Unknown"
        case .busy: owners.compactMap { $0 }.first ?? "Unknown"
        }
    }

    var ownerDescription: String {
        switch state {
        case .idle: "Idle"
        case .unknown: "Availability unknown"
        case .busy where owners.compactMap({ $0 }).isEmpty: "In use by an unknown user"
        case .busy: "In use by " + owners.map { $0 ?? "unknown user" }.joined(separator: ", ")
        }
    }
}

struct GPUHost: Decodable, Identifiable, Sendable {
    let host: String
    let cards: [GPUCard]
    let error: String?

    var id: String { host }
    var isReachable: Bool { error == nil && !cards.isEmpty }

    subscript(_ state: GPUState) -> Int { cards.filter { $0.state == state }.count }
}

struct GPUReport: Sendable {
    let hosts: [GPUHost]
    let message: String?
    let checkedAt = Date()

    var reachableCount: Int { hosts.filter(\.isReachable).count }
    var unavailableCount: Int { hosts.count - reachableCount }

    var orderedHosts: [GPUHost] {
        hosts.sorted { a, b in
            let order = a.id.compare(b.id, options: [.caseInsensitive, .numeric])
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    subscript(_ state: GPUState) -> Int { hosts.reduce(0) { $0 + $1[state] } }
}

enum GPUCheck {
    static func poll() -> GPUReport {
        do {
            return try run()
        } catch {
            return GPUReport(hosts: [], message: error.localizedDescription)
        }
    }

    static func parse(_ output: Data) throws -> [GPUHost] {
        try JSONDecoder().decode([GPUHost].self, from: output)
    }

    private static func run() throws -> GPUReport {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        let bundledCommand = Bundle.main.url(forResource: "check_gpu_util", withExtension: nil)?.path
        guard let command = environment["CHECK_GPU_UTIL"] ?? bundledCommand, files.isExecutableFile(atPath: command) else {
            return GPUReport(hosts: [], message: "Couldn’t run the bundled check_gpu_util.")
        }

        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        try Data().write(to: outputURL)
        try Data().write(to: errorURL)
        let stdout = try FileHandle(forWritingTo: outputURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: errorURL)
        defer { try? stderr.close() }

        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:\(inheritedPath)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["--json"]
        process.currentDirectoryURL = home
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()

        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.10)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            return GPUReport(hosts: [], message: "The GPU check timed out.")
        }

        let result = try Data(contentsOf: outputURL)
        guard let hosts = try? parse(result), !hosts.isEmpty else {
            let errorText = try String(contentsOf: errorURL, encoding: .utf8)
            let message = errorText.split(whereSeparator: \.isNewline).last.map(String.init)
                ?? "check_gpu_util returned no per-card readings."
            return GPUReport(hosts: [], message: message)
        }
        // The command exits nonzero when any host fails, even when others return valid data.
        return GPUReport(hosts: hosts, message: nil)
    }
}
