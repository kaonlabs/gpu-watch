import AppKit
import SwiftUI

@MainActor
final class GPUStore: ObservableObject {
    static let interval: TimeInterval = 60

    @Published private(set) var report: GPUReport?
    @Published private(set) var isChecking = false

    var didChange: (() -> Void)?
    private var timer: Timer?

    func start() {
        refresh()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard !isChecking else { return }
        isChecking = true
        didChange?()
        Task {
            report = await Task.detached(priority: .utility) { GPUCheck.poll() }.value
            isChecking = false
            didChange?()
        }
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private let store = GPUStore()
    private let popover = NSPopover()
    private var item: NSStatusItem?
    private var dashboardWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "GPUWatchAvailability"
        item.isVisible = true
        item.button?.image = Self.chipImage()
        item.button?.imagePosition = .imageLeft
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        item.button?.target = self
        item.button?.action = #selector(toggleDashboard(_:))
        self.item = item
        store.didChange = { [weak self] in
            self?.updateStatusItem()
            self?.resizeDashboards()
        }
        store.start()
        showDashboardWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboardWindow()
        return false
    }

    private static func chipImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor(srgbRed: 0.26, green: 0.67, blue: 0.51, alpha: 1).setFill()
            for offset in [4.5, 8.25, 12] {
                NSBezierPath(rect: NSRect(x: offset, y: 0.5, width: 1.5, height: 17)).fill()
                NSBezierPath(rect: NSRect(x: 0.5, y: offset, width: 17, height: 1.5)).fill()
            }
            NSColor(srgbRed: 0.67, green: 0.95, blue: 0.79, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 12, height: 12), xRadius: 2.5, yRadius: 2.5).fill()
            NSColor(srgbRed: 0.08, green: 0.30, blue: 0.25, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 6, y: 6, width: 6, height: 6), xRadius: 1.4, yRadius: 1.4).fill()
            return true
        }
        image.accessibilityDescription = "GPU Watch"
        return image
    }

    private func updateStatusItem() {
        guard let button = item?.button else { return }
        if let report = store.report, report.reachableCount > 0 {
            button.title = " \(report[.idle])"
            let missing = report.unavailableCount
            button.toolTip = missing > 0
                ? "GPU Watch · \(report[.idle]) idle · \(missing) hosts unavailable"
                : "GPU Watch · \(report[.idle]) idle GPUs"
        } else {
            button.title = " –"
            button.toolTip = store.isChecking ? "GPU Watch · Checking hosts" : "GPU Watch · Readings unavailable"
        }
        button.setAccessibilityLabel(button.toolTip ?? "GPU Watch")
    }

    @objc private func toggleDashboard(_ button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            let layout = DashboardLayout(screen: button.window?.screen, hosts: store.report?.hosts ?? [])
            let view = Dashboard(store: store, layout: layout)
            if let controller = popover.contentViewController as? NSHostingController<Dashboard> {
                controller.rootView = view
            } else {
                popover.contentViewController = NSHostingController(rootView: view)
            }
            popover.contentSize = layout.size
            dashboardWindow?.orderOut(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showDashboardWindow() {
        if popover.isShown { popover.performClose(nil) }
        if dashboardWindow == nil {
            let layout = DashboardLayout(screen: NSScreen.main, hosts: store.report?.hosts ?? [])
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: layout.size),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "GPU Watch"
            window.contentViewController = NSHostingController(rootView: Dashboard(store: store, layout: layout))
            window.isReleasedWhenClosed = false
            window.center()
            dashboardWindow = window
        }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        dashboardWindow?.makeKeyAndOrderFront(nil)
    }

    private func resizeDashboards() {
        let hosts = store.report?.hosts ?? []
        if let window = dashboardWindow,
           let controller = window.contentViewController as? NSHostingController<Dashboard> {
            let layout = DashboardLayout(screen: window.screen, hosts: hosts)
            if controller.rootView.layout != layout {
                controller.rootView = Dashboard(store: store, layout: layout)
                window.setContentSize(layout.size)
                if let screen = window.screen {
                    window.setFrame(window.constrainFrameRect(window.frame, to: screen), display: true)
                }
            }
        }
        if popover.isShown, let controller = popover.contentViewController as? NSHostingController<Dashboard> {
            let layout = DashboardLayout(screen: item?.button?.window?.screen, hosts: hosts)
            if controller.rootView.layout != layout {
                controller.rootView = Dashboard(store: store, layout: layout)
                popover.contentSize = layout.size
            }
        }
    }
}

private enum Palette {
    static let paper = adaptive(0xF8F9F6, 0x181D20)
    static let inset = adaptive(0xEDF0EB, 0x22292C)
    static let ink = adaptive(0x24302E, 0xE6EAE7)
    static let secondary = adaptive(0x56635F, 0xAEBBB5)
    static let rule = adaptive(0xD6DCD7, 0x39413F)
    static let track = adaptive(0xDADFD9, 0x343C3B)
    static let gpu = adaptive(0x596D68, 0xADBEB8)
    static let memory = adaptive(0x829691, 0x7F9590)
    static let free = adaptive(0x136747, 0x96D7B2)
    static let onFree = adaptive(0xFFFFFF, 0x123329)
    static let mine = adaptive(0x366DA8, 0x79ACE0)
    static let onMine = adaptive(0xFFFFFF, 0x10283E)
    static let mineInk = adaptive(0x245E9A, 0xAACFF5)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(value >> 16) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

private struct DashboardLayout: Equatable {
    static let inset: CGFloat = 16
    static let machineWidth: CGFloat = 96
    static let hostGap: CGFloat = 5
    static let header: CGFloat = 61
    static let columnHeader: CGFloat = 23
    static let legend: CGFloat = 30
    static let inspector: CGFloat = 58

    let size: NSSize
    let bands: [[Int]]
    let cellWidth: CGFloat
    let rowHeight: CGFloat
    let needsScroll: Bool

    init(screen: NSScreen?, hosts: [GPUHost]) {
        let available = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
        let width = min(452, available.width - 32)
        let heightLimit = available.height - 40
        let gridWidth = width - 2 * Self.inset - Self.machineWidth - Self.hostGap
        let columns = max(1, min(8, Int(gridWidth / 28)))
        cellWidth = gridWidth / CGFloat(columns)
        let indices = Set(hosts.filter(\.isReachable).flatMap { $0.cards.map(\.index) }).sorted()
        bands = indices.isEmpty ? [[]] : stride(from: 0, to: indices.count, by: columns).map {
            Array(indices[$0..<min($0 + columns, indices.count)])
        }
        var rows = 0
        for (index, band) in bands.enumerated() {
            rows += hosts.filter { Self.shows($0, in: band, first: index == 0) }.count
        }
        let chrome = Self.header + Self.legend + Self.inspector + 2 + CGFloat(bands.count) * Self.columnHeader
        rowHeight = max(26, min(35, floor((heightLimit - chrome) / CGFloat(max(1, rows)))))
        let height = hosts.isEmpty ? Self.header + 78 : chrome + CGFloat(rows) * rowHeight
        size = NSSize(width: width, height: min(height, heightLimit))
        needsScroll = height > heightLimit
    }

    static func shows(_ host: GPUHost, in band: [Int], first: Bool) -> Bool {
        host.isReachable ? host.cards.contains { band.contains($0.index) } : first
    }
}

private struct Selection: Equatable {
    let host: String
    let index: Int
}

private struct Dashboard: View {
    @ObservedObject var store: GPUStore
    let layout: DashboardLayout
    @State private var hovered: Selection?
    @State private var pinned: Selection?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let report = store.report, !report.hosts.isEmpty {
                let hosts = report.orderedHosts
                let selection = selectedCard(in: hosts)
                let active = selection.map { Selection(host: $0.0.id, index: $0.1.index) }
                rule
                if layout.needsScroll {
                    ScrollView { matrix(hosts, active: active) }
                } else {
                    matrix(hosts, active: active)
                }
                legend
                rule
                inspector(selection)
            } else {
                emptyView
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
    }

    private var rule: some View {
        Rectangle().fill(Palette.rule).frame(height: 1).accessibilityHidden(true)
    }

    private var headline: String {
        guard let report = store.report, report.reachableCount > 0 else { return "GPU availability" }
        let free = report[.idle]
        if free > 0 { return free == 1 ? "1 GPU free" : "\(free) GPUs free" }
        if report.unavailableCount > 0 || report[.unknown] > 0 { return "No confirmed free GPUs" }
        return "All GPUs in use"
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle((store.report?[.idle] ?? 0) > 0 ? Palette.free : Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                if let report = store.report, !report.hosts.isEmpty {
                    let count = report.hosts.reduce(0) { $0 + $1.cards.count }
                    Text("\(count) GPUs  ·  \(report.reachableCount)/\(report.hosts.count) machines reporting")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.secondary)
                }
            }
            Spacer(minLength: 3)
            Button(action: store.refresh) {
                Image(systemName: "arrow.clockwise").frame(width: 23, height: 25)
            }
            .disabled(store.isChecking)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh GPU readings")
            .accessibilityLabel("Refresh GPU readings")
            Menu {
                if let report = store.report {
                    Text("Updated \(report.checkedAt.formatted(date: .omitted, time: .standard))")
                    Divider()
                }
                Button("Quit GPU Watch") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 23, height: 25)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("GPU Watch options")
        }
        .font(.system(size: 14))
        .buttonStyle(.plain)
        .padding(.horizontal, DashboardLayout.inset)
        .frame(height: DashboardLayout.header)
    }

    private func selectedCard(in hosts: [GPUHost]) -> (GPUHost, GPUCard)? {
        for candidate in [hovered, pinned].compactMap({ $0 }) {
            if let host = hosts.first(where: { $0.id == candidate.host && $0.isReachable }),
               let card = host.cards.first(where: { $0.index == candidate.index }) {
                return (host, card)
            }
        }
        for host in hosts where host.isReachable {
            if let card = host.cards.first(where: { $0.state == .idle }) { return (host, card) }
        }
        guard let host = hosts.first(where: \.isReachable), let card = host.cards.first else { return nil }
        return (host, card)
    }

    private func matrix(_ hosts: [GPUHost], active: Selection?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(layout.bands.indices, id: \.self) { number in
                let band = layout.bands[number]
                HStack(spacing: 0) {
                    Text("Machine")
                        .frame(width: DashboardLayout.machineWidth + DashboardLayout.hostGap, alignment: .leading)
                    ForEach(band, id: \.self) { index in
                        Text("\(index)").monospacedDigit().frame(width: layout.cellWidth)
                            .accessibilityLabel("GPU \(index)")
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Palette.secondary)
                .frame(height: DashboardLayout.columnHeader)
                ForEach(hosts.filter { DashboardLayout.shows($0, in: band, first: number == 0) }) { host in
                    HostRow(host: host, band: band, layout: layout, active: active,
                            onHover: { key, inside in
                                if inside { hovered = key } else if hovered == key { hovered = nil }
                            },
                            onSelect: { pinned = $0 })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DashboardLayout.inset)
    }

    private var legend: some View {
        let logins = Set(store.report?.hosts.compactMap(\.loginUser) ?? [])
        let label: String
        if logins.count == 1, let login = logins.first { label = "Yours (\(login))" }
        else { label = "Yours" }
        return HStack(spacing: 5) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.free)
            Text("Free")
            Capsule().fill(Palette.mine)
                .frame(width: 15, height: 11)
                .padding(.leading, 9)
            Text(label).lineLimit(1).fontWeight(.semibold).foregroundStyle(Palette.mineInk)
                .help("GPUs used by your SSH login on each machine")
            Spacer(minLength: 4)
            Text("Outer GPU load  ·  Inner VRAM")
        }
        .font(.system(size: 11))
        .foregroundStyle(Palette.secondary)
        .padding(.horizontal, DashboardLayout.inset)
        .frame(height: DashboardLayout.legend)
    }

    @ViewBuilder
    private func inspector(_ selection: (GPUHost, GPUCard)?) -> some View {
        Group {
            if let (host, card) = selection {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("\(host.id)  /  GPU \(card.index)").fontWeight(.semibold)
                        Text(card.ownerLine)
                            .foregroundStyle(card.state == .idle ? Palette.free : Palette.secondary)
                            .lineLimit(1)
                    }
                    .font(.system(size: 13))
                    HStack(spacing: 5) {
                        Text("GPU load").foregroundStyle(Palette.secondary)
                        Text(card.percent).fontWeight(.semibold)
                        Text("VRAM").foregroundStyle(Palette.secondary).padding(.leading, 8)
                        Text(card.vramPercent).fontWeight(.semibold)
                        if card.vramFraction != nil, let used = card.vramUsedMiB, let total = card.vramTotalMiB {
                            Text("(\(used.formatted()) / \(total.formatted()) MiB)")
                                .foregroundStyle(Palette.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.system(size: 12)).monospacedDigit()
                }
                .help("\(host.id) · GPU \(card.index)\n\(card.ownerDescription)\nGPU load \(card.percent)\n\(card.vramDescription)")
                .accessibilityElement(children: .combine)
            } else {
                Text("No GPU readings available").foregroundStyle(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DashboardLayout.inset)
        .frame(height: DashboardLayout.inspector)
        .background(Palette.inset)
    }

    private var emptyView: some View {
        HStack(spacing: 8) {
            if store.isChecking { ProgressView().controlSize(.small) }
            Text(store.isChecking ? "Checking GPU hosts…" : store.report?.message ?? "GPU readings unavailable")
                .foregroundStyle(Palette.secondary)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
        .padding(.horizontal, DashboardLayout.inset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HostRow: View {
    let host: GPUHost
    let band: [Int]
    let layout: DashboardLayout
    let active: Selection?
    let onHover: (Selection, Bool) -> Void
    let onSelect: (Selection) -> Void
    @State private var showingAssignments = false

    private func summary(_ occupants: [GPUOccupant]) -> String {
        guard host.isReachable else { return "Unavailable" }
        let users = occupants.compactMap { occupant -> String? in
            guard case .user(let name) = occupant else { return nil }
            return name
        }
        var parts: [String] = []
        if host[.idle] > 0 { parts.append("\(host[.idle]) free") }
        if users.count > 1 { parts.append("\(users.count) users") }
        else if let user = users.first { parts.append(user) }
        if parts.isEmpty { return occupants.contains(.unknownUser) ? "Owner unknown" : "Unknown" }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let assignments = host.assignments
        let occupants = assignments.map(\.occupant)
        let hasBusyCards = host[.busy] > 0
        let labelsVisible = layout.rowHeight >= 31 && hasBusyCards && occupants.count > 1
        let captionHeight: CGFloat = labelsVisible ? 12 : 0
        let dialHeight = layout.rowHeight - captionHeight
        HStack(spacing: DashboardLayout.hostGap) {
            Button { showingAssignments = true } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text(host.id).font(.system(size: 13, weight: .semibold))
                        if occupants.count > 1 {
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .medium))
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                    Text(summary(occupants))
                        .font(.system(size: 11))
                        .foregroundStyle(host[.idle] > 0 ? Palette.free : Palette.secondary)
                }
                .lineLimit(1)
                .frame(width: DashboardLayout.machineWidth, height: layout.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!host.isReachable)
            .help("Show GPU assignments for \(host.id)")
            .accessibilityLabel("\(host.id), \(summary(occupants)), show GPU assignments")
            .popover(isPresented: $showingAssignments, arrowEdge: .trailing) {
                AssignmentList(host: host.id, loginUser: host.loginUser, assignments: assignments)
            }
            if host.isReachable {
                let cards = band.map { index in host.cards.first { $0.index == index } }
                let owned = cards.map { $0?.isOwned(by: host.loginUser) == true }
                ZStack(alignment: .leading) {
                    // A continuous tint marks adjacent GPUs owned by this host's SSH user.
                    ForEach(cards.indices, id: \.self) { i in
                        if owned[i] && (i == 0 || !owned[i - 1]) {
                            let end = owned[i...].firstIndex(of: false) ?? cards.endIndex
                            Capsule().fill(Palette.mine)
                                .frame(width: CGFloat(end - i) * layout.cellWidth - 4, height: min(28, dialHeight))
                                .offset(x: CGFloat(i) * layout.cellWidth + 2, y: -captionHeight / 2)
                                .accessibilityHidden(true)
                        }
                    }
                    HStack(spacing: 0) {
                        ForEach(cards.indices, id: \.self) { i in
                            if let card = cards[i] {
                                let key = Selection(host: host.id, index: card.index)
                                let isMine = owned[i]
                                Button { onSelect(key) } label: {
                                    GPUDial(card: card, isMine: isMine)
                                        .frame(width: min(23, dialHeight - 4), height: min(23, dialHeight - 4))
                                        .padding(2)
                                        .overlay {
                                            if active == key {
                                                RoundedRectangle(cornerRadius: 6)
                                                    .strokeBorder(isMine ? Palette.onMine : Palette.ink, lineWidth: 1)
                                            }
                                        }
                                        .frame(width: layout.cellWidth, height: dialHeight)
                                        .padding(.bottom, captionHeight)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .onHover { onHover(key, $0) }
                                .help("\(host.id) · GPU \(card.index)\n\(card.ownerDescription)\nGPU load \(card.percent)\n\(card.vramDescription)")
                                .accessibilityLabel("\(host.id), GPU \(card.index), \(card.ownerDescription), GPU load \(card.percent), \(card.vramDescription)")
                            } else {
                                Text("–").foregroundStyle(Palette.secondary)
                                    .frame(width: layout.cellWidth, height: layout.rowHeight)
                                    .accessibilityLabel("GPU \(band[i]) not reported")
                            }
                        }
                    }
                    if labelsVisible {
                        ForEach(OwnerRun.runs(in: cards)) { run in
                            ViewThatFits(in: .horizontal) {
                                Text(run.names).fixedSize()
                                HStack(spacing: 2) {
                                    Text(run.primaryLabel(for: host.loginUser))
                                    if run.owners.count > 1 { Text("+\(run.owners.count - 1)").fixedSize() }
                                }
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(run.includes(host.loginUser) ? Palette.mineInk : Palette.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 2)
                            .frame(width: CGFloat(run.columns.count) * layout.cellWidth, height: captionHeight)
                            .offset(x: CGFloat(run.columns.lowerBound) * layout.cellWidth, y: dialHeight / 2)
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            } else {
                Text(host.error ?? "No readings")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(1)
                    .help(host.error ?? "No readings")
            }
        }
        .frame(height: layout.rowHeight)
        .accessibilityElement(children: .contain)
    }
}

private struct OwnerRun: Identifiable {
    let columns: Range<Int>
    let owners: [GPUOccupant]
    var id: Int { columns.lowerBound }
    var names: String { owners.map(\.label).joined(separator: " + ") }
    func includes(_ loginUser: String?) -> Bool {
        guard let loginUser else { return false }
        return owners.contains(.user(loginUser))
    }

    func primaryLabel(for loginUser: String?) -> String {
        if let loginUser, includes(loginUser) { return loginUser }
        if owners.first == .unknownUser { return "User ?" }
        return owners.first?.label ?? "?"
    }

    static func runs(in cards: [GPUCard?]) -> [OwnerRun] {
        var runs: [OwnerRun] = []
        for (column, card) in cards.enumerated() {
            guard let card, card.state == .busy else { continue }
            let owners = card.occupants
            if let last = runs.last, last.columns.upperBound == column, last.owners == owners {
                runs[runs.count - 1] = OwnerRun(columns: last.columns.lowerBound..<(column + 1), owners: owners)
            } else {
                runs.append(OwnerRun(columns: column..<(column + 1), owners: owners))
            }
        }
        return runs
    }
}

private struct AssignmentList: View {
    let host: String
    let loginUser: String?
    let assignments: [GPUAssignment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(host) · GPU assignments").font(.system(size: 14, weight: .semibold))
            if assignments.count > 10 {
                ScrollView { rows }.frame(height: 240)
            } else {
                rows
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(Palette.paper)
    }

    private var rows: some View {
        VStack(spacing: 7) {
            ForEach(assignments) { assignment in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(assignment.occupant.label)
                        .foregroundStyle(assignment.occupant == .free ? Palette.free : Palette.ink)
                        .fontWeight(assignment.occupant == loginUser.map(GPUOccupant.user) ? .semibold : .regular)
                    Spacer(minLength: 0)
                    Text("GPU \(assignment.gpuNumbers)")
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .font(.system(size: 12))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct GPUDial: View {
    let card: GPUCard
    let isMine: Bool

    var body: some View {
        ZStack {
            if card.state == .idle { Circle().fill(Palette.free) }
            ring(card.utilization.map { Double($0) / 100 }, color: Palette.gpu, width: 2)
            ring(card.vramFraction, color: Palette.memory, width: 1.6).padding(3.6)
            switch card.state {
            case .idle:
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.onFree)
            case .unknown:
                Text("?").font(.system(size: 9, weight: .semibold)).foregroundStyle(Palette.secondary)
            case .busy:
                EmptyView()
            }
        }
    }

    private func ring(_ fraction: Double?, color: Color, width: CGFloat) -> some View {
        let circle = Circle().inset(by: width / 2)
        let fill: Color
        let track: Color
        if isMine {
            fill = Palette.onMine
            track = fill.opacity(0.30)
        } else if card.state == .idle {
            fill = Palette.onFree
            track = fill.opacity(0.20)
        } else {
            fill = color
            track = Palette.track
        }
        return ZStack {
            circle.stroke(track, style: StrokeStyle(lineWidth: width, dash: fraction == nil ? [2, 2] : []))
            if let fraction, fraction > 0 {
                circle.trim(from: 0, to: min(1, fraction))
                    .stroke(fill, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

@main
@MainActor
enum GPUWatch {
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}
