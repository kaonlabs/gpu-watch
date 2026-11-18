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
        popover.contentSize = Dashboard.size
        popover.contentViewController = NSHostingController(rootView: Dashboard(store: store))

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "GPUWatchAvailability"
        item.isVisible = true
        item.button?.image = Self.chipImage()
        item.button?.imagePosition = .imageLeft
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        item.button?.target = self
        item.button?.action = #selector(toggleDashboard(_:))
        self.item = item
        store.didChange = { [weak self] in self?.updateStatusItem() }
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
            dashboardWindow?.orderOut(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showDashboardWindow() {
        if popover.isShown { popover.performClose(nil) }
        if dashboardWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: Dashboard.size),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "GPU Watch"
            window.contentViewController = NSHostingController(rootView: Dashboard(store: store))
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
}

private enum Palette {
    static let background = Color(red: 0.075, green: 0.10, blue: 0.16)
    static let panel = Color(red: 0.11, green: 0.15, blue: 0.22)
    static let rule = Color(red: 0.21, green: 0.26, blue: 0.35)
    static let text = Color(red: 0.92, green: 0.94, blue: 0.99)
    static let muted = Color(red: 0.65, green: 0.71, blue: 0.80)
}

private extension GPUState {
    var color: Color {
        switch self {
        case .idle: Color(red: 0.70, green: 0.96, blue: 0.79)
        case .busy: Color(red: 0.66, green: 0.75, blue: 0.95)
        case .unknown: Color(red: 1, green: 0.80, blue: 0.55)
        }
    }

    var symbol: String {
        switch self {
        case .idle: "circle"
        case .busy: "circle.fill"
        case .unknown: "questionmark"
        }
    }
}

private struct Dashboard: View {
    private struct CardSelection {
        let host: String
        let index: Int
    }

    static let size = NSSize(width: 570, height: 752)
    @ObservedObject var store: GPUStore
    @State private var inspectedCard: CardSelection?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Palette.rule).frame(height: 1)
            if let report = store.report, !report.hosts.isEmpty {
                hostList(report)
            } else {
                emptyView
            }
            Rectangle().fill(Palette.rule).frame(height: 1)
            if store.report?.reachableCount ?? 0 > 0 {
                cardDetails
                Rectangle().fill(Palette.rule).frame(height: 1)
            }
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .foregroundStyle(Palette.text)
        .background(Palette.background)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        let report = store.report
        let hasReadings = (report?.reachableCount ?? 0) > 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("GPU Watch", systemImage: "cpu")
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if let report, report.unavailableCount > 0 {
                    Label("\(report.unavailableCount) unavailable", systemImage: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(GPUState.unknown.color)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(hasReadings ? String(report?[.idle] ?? 0) : "–")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(hasReadings && (report?[.idle] ?? 0) > 0 ? GPUState.idle.color : Palette.muted)
                Text("idle GPUs")
                    .font(.system(size: 16, weight: .medium))
                Spacer()
                if let report, !report.hosts.isEmpty {
                    Text("\(report.reachableCount)/\(report.hosts.count) hosts reporting")
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Palette.muted)
                }
            }
            .accessibilityElement(children: .combine)
            if let report, hasReadings {
                capacityBar(report)
                HStack(spacing: 16) {
                    ForEach(GPUState.allCases, id: \.self) { state in
                        Label("\(report[state]) \(state.rawValue)", systemImage: state.symbol)
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(state.color)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 15)
        .background(Palette.panel)
    }

    private func capacityBar(_ report: GPUReport) -> some View {
        let activeStates = GPUState.allCases.filter { report[$0] > 0 }
        let total = activeStates.reduce(0) { $0 + report[$1] }
        let gap: CGFloat = 3
        return GeometryReader { geometry in
            let remaining = max(0, geometry.size.width - gap * CGFloat(activeStates.count - 1))
            HStack(spacing: gap) {
                ForEach(activeStates, id: \.self) { state in
                    Capsule()
                        .fill(state.color)
                        .frame(width: remaining * CGFloat(report[state]) / CGFloat(total))
                }
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private func hostList(_ report: GPUReport) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(report.orderedHosts) { host in
                    HostRow(host: host) { index in
                        inspectedCard = CardSelection(host: host.id, index: index)
                    }
                    Rectangle().fill(Palette.rule.opacity(0.58)).frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var cardDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let inspectedCard,
               let host = store.report?.hosts.first(where: { $0.id == inspectedCard.host }),
               let card = host.cards.first(where: { $0.index == inspectedCard.index }) {
                Text("\(host.id) · GPU \(card.index) · \(card.percent)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(card.state.color)
                Text(card.ownerDescription)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .help(card.ownerDescription)
            } else {
                Text("Hover over or click a GPU for owner details")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 43, alignment: .leading)
        .padding(.horizontal, 20)
        .background(Palette.panel)
        .accessibilityElement(children: .combine)
    }

    private var emptyView: some View {
        VStack(spacing: 9) {
            if store.isChecking {
                ProgressView().controlSize(.small)
                Text("Checking GPU hosts…").font(.system(size: 13, weight: .medium))
            } else {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(GPUState.unknown.color)
                Text("GPU readings unavailable").font(.system(size: 14, weight: .semibold))
                if let message = store.report?.message {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if store.isChecking {
                Text("Checking…")
            } else if let report = store.report {
                Text("Checked \(report.checkedAt.formatted(.dateTime.hour().minute().second()))")
            } else {
                Text("Checks every minute")
            }
            Spacer()
            Button(action: store.refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isChecking)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh GPU readings")
            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
                    .accessibilityLabel("Quit GPU Watch")
            }
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit GPU Watch")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Palette.muted)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 20)
        .frame(height: 45)
        .background(Palette.panel)
    }
}

private struct HostRow: View {
    let host: GPUHost
    let inspect: (Int) -> Void
    private let slots = Array(repeating: GridItem(.fixed(45), spacing: 5), count: 8)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(host.id)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 61, height: 42, alignment: .leading)
            if host.isReachable {
                LazyVGrid(columns: slots, alignment: .leading, spacing: 5) {
                    ForEach(host.cards) { card in
                        CardTile(card: card) { inspect(card.index) }
                    }
                }
                Text("\(host[.idle]) idle")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(host[.idle] > 0 ? GPUState.idle.color : Palette.muted)
                    .frame(width: 54, height: 42, alignment: .trailing)
            } else {
                let reason = host.error ?? "No readings"
                Label(reason, systemImage: "minus.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .help(reason)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

private struct CardTile: View {
    let card: GPUCard
    let inspect: () -> Void
    @State private var hovered = false

    private var tooltip: String {
        let usage = card.utilization.map { "\($0)% utilization" } ?? "Utilization unavailable"
        return "GPU \(card.index) · \(usage)\n\(card.ownerDescription)"
    }

    var body: some View {
        let tint = card.state.color
        let fill = card.state == .idle ? tint : tint.opacity(0.12)
        let text = card.state == .idle ? Palette.background : tint
        Button(action: inspect) {
            VStack(spacing: 1) {
                Text("\(card.index)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(text.opacity(0.78))
                Text(card.percent)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(text)
                ZStack(alignment: .leading) {
                    Capsule().fill(text.opacity(0.22))
                    if let utilization = card.utilization, utilization > 0 {
                        Capsule().fill(text).frame(width: 29 * CGFloat(utilization) / 100)
                    }
                }
                .frame(width: 29, height: 2)
                Text(card.ownerBadge)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(text)
                    .lineLimit(1)
                    .padding(.horizontal, 2)
            }
            .frame(width: 45, height: 42)
            .background(fill, in: RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(tint.opacity(hovered ? 1 : 0.48), style: StrokeStyle(
                        lineWidth: hovered ? 2 : 1, dash: card.state == .unknown ? [2, 2] : []
                    ))
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside
                if inside { inspect() }
            }
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(tooltip)
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
