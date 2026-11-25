import Darwin
import Foundation

enum GPUState: String, CaseIterable, Decodable, Sendable {
    case idle, busy, unknown
}

enum GPUOccupant: Hashable {
    case free, user(String), unknownUser, unknownState

    var label: String {
        switch self {
        case .free: "Free"
        case .user(let name): name
        case .unknownUser: "Owner unknown"
        case .unknownState: "Availability unknown"
        }
    }
}

struct GPUAssignment: Identifiable {
    let occupant: GPUOccupant
    let indices: [Int]
    var id: GPUOccupant { occupant }

    var gpuNumbers: String {
        var ranges: [ClosedRange<Int>] = []
        for index in indices.sorted() {
            if let last = ranges.last, last.upperBound < index, last.upperBound + 1 == index {
                ranges[ranges.count - 1] = last.lowerBound...index
            } else {
                ranges.append(index...index)
            }
        }
        return ranges.map { $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)–\($0.upperBound)" }
            .joined(separator: ", ")
    }
}

struct GPUCard: Decodable, Identifiable, Sendable {
    let index: Int
    let utilization: Int?
    let vramUsedMiB: Int?
    let vramTotalMiB: Int?
    let state: GPUState
    let owners: [String?]

    var id: Int { index }
    var percent: String { utilization.map { "\($0)%" } ?? "–" }
    var vramFraction: Double? {
        guard let vramUsedMiB, let vramTotalMiB, vramTotalMiB > 0,
              (0...vramTotalMiB).contains(vramUsedMiB) else { return nil }
        return Double(vramUsedMiB) / Double(vramTotalMiB)
    }

    var vramPercent: String { vramFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    var vramDescription: String {
        guard vramFraction != nil, let vramUsedMiB, let vramTotalMiB else { return "VRAM unavailable" }
        return "VRAM \(vramUsedMiB.formatted()) / \(vramTotalMiB.formatted()) MiB (\(vramPercent))"
    }

    var occupants: [GPUOccupant] {
        switch state {
        case .idle: return [.free]
        case .unknown: return [.unknownState]
        case .busy:
            let users = Set(owners.compactMap { $0 }).sorted().map(GPUOccupant.user)
            return users.isEmpty || owners.contains(nil) ? users + [.unknownUser] : users
        }
    }

    var ownerLine: String { occupants.map(\.label).joined(separator: ", ") }

    func isOwned(by loginUser: String?) -> Bool {
        guard state == .busy, let loginUser else { return false }
        return owners.contains(loginUser)
    }

    var ownerDescription: String {
        guard state == .busy else { return ownerLine }
        let names = occupants.map { $0 == .unknownUser ? "unknown user" : $0.label }
        return "In use by " + names.joined(separator: ", ")
    }
}

struct GPUHost: Decodable, Identifiable, Sendable {
    let host: String
    let cards: [GPUCard]
    let error: String?
    let loginUser: String?

    var id: String { host }
    var isReachable: Bool { error == nil && !cards.isEmpty }

    var assignments: [GPUAssignment] {
        var indices: [GPUOccupant: [Int]] = [:]
        for card in cards {
            for occupant in card.occupants {
                indices[occupant, default: []].append(card.index)
            }
        }
        let users = indices.keys.compactMap { occupant -> String? in
            guard case .user(let name) = occupant else { return nil }
            return name
        }.sorted()
        let order: [GPUOccupant] = [.free] + users.map(GPUOccupant.user) + [.unknownUser, .unknownState]
        return order.compactMap { occupant in
            indices[occupant].map { GPUAssignment(occupant: occupant, indices: $0) }
        }
    }

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
