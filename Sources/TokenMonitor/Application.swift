import Foundation
import AppKit
import SwiftUI

@main
struct TokenMonitorEntry {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--claude-probe") {
            do {
                let state = try ClaudeUsageProbe.read()
                let summary: [String: Any] = ["source": "claude-official-cli", "capturedAt": state.updatedAt!.timeIntervalSince1970,
                    "windows": state.windows.map { window -> [String: Any] in
                        ["id": window.id, "usedPercent": window.usedPercent as Any? ?? NSNull(),
                         "resetsAt": window.resetsAt?.timeIntervalSince1970 as Any? ?? NSNull()]
                    }]
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                print(String(decoding: data, as: UTF8.self))
                exit(0)
            } catch {
                print((error as? ClaudeUsageError)?.message ?? "无法读取 Claude 额度")
                exit(1)
            }
        }
if CommandLine.arguments.contains("--probe") {
    do {
        let windows = QuotaParser.codex(try CodexProbe.read())
        let summary: [String: Any] = ["source": "codex", "capturedAt": Date().timeIntervalSince1970, "windows": windows.map { window -> [String: Any] in
            ["id": window.id, "name": window.name, "usedPercent": window.usedPercent as Any? ?? NSNull(), "resetsAt": window.resetsAt?.timeIntervalSince1970 as Any? ?? NSNull()]
        }]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch {
        print((error as? ProbeError)?.message ?? "无法读取额度")
        exit(1)
    }
}
        let instanceLock: SingleInstanceLock
        do {
            guard let acquired = try SingleInstanceLock.acquire() else {
                DistributedNotificationCenter.default().postNotificationName(
                    SingleInstanceLock.revealNotificationName, object: nil, userInfo: nil, deliverImmediately: true)
                return
            }
            instanceLock = acquired
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法启动 Token Monitor"
            alert.informativeText = "无法建立单实例锁。请检查应用数据目录的权限后重试。"
            alert.runModal()
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime((instanceLock, delegate)) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var handle: NSPanel!
    private var store: MonitorStore!
    private var expandedFrame = NSRect.zero
    private var naturalHeight: CGFloat = 176
    private var naturalHandleSize = EdgeHandleView.size
    private var collapsedFrame: NSRect?
    private var handleIsDocked = true
    private var renderedHandleEdge: ScreenEdge?
    private var handleViewGeneration = 0
    private var isCollapsed = UserDefaults.standard.bool(forKey: "edgeCollapsed")
    private var edge = ScreenEdge.right
    private var isPositioning = false
    private var transitionTimer: Timer?
    private var transitionStartedAt: TimeInterval = 0
    private var transitionStep: ((CGFloat) -> Void)?
    private var transitionCompletion: (() -> Void)?

    private var preferredWidth: CGFloat { store.compact ? 360 : 390 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = MonitorStore(demo: CommandLine.arguments.contains("--demo"))
        let content = MonitorView(store: store,
            onClose: { [weak self] in self?.hidePanels() },
            onToggleCompact: { [weak self] in self?.toggleCompact() },
            onToggleEdge: { [weak self] in self?.toggleEdge() },
            onHeightChange: { [weak self] height in
                DispatchQueue.main.async { self?.resizeContent(to: height) }
            })
        panel = FloatingQuotaPanel(contentRect: NSRect(x: 0, y: 0, width: preferredWidth, height: naturalHeight),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = FloatingWindowGlassView.hosting(content,
            frame: NSRect(x: 0, y: 0, width: preferredWidth, height: naturalHeight))
        configure(panel)
        panel.isMovableByWindowBackground = true
        panel.setFrameAutosaveName("TokenMonitorFloatingPanel")
        if !panel.setFrameUsingName("TokenMonitorFloatingPanel") {
            if let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - preferredWidth - 12, y: screen.visibleFrame.maxY - naturalHeight - 24))
            }
        }
        var restoredFrame = panel.frame
        restoredFrame.origin.x += restoredFrame.width - preferredWidth
        restoredFrame.origin.y += restoredFrame.height - naturalHeight
        restoredFrame.size = NSSize(width: preferredWidth, height: naturalHeight)
        expandedFrame = constrained(restoredFrame)
        panel.setFrame(expandedFrame, display: false)
        panel.delegate = self

        handle = FloatingQuotaPanel(contentRect: NSRect(origin: .zero, size: EdgeHandleView.size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configure(handle)
        handle.title = "额度缩略窗"
        handle.isMovableByWindowBackground = false
        if let raw = UserDefaults.standard.string(forKey: "edgeSide"), let stored = ScreenEdge(rawValue: raw) { edge = stored }
        if edge == .top { naturalHandleSize = NSSize(width: 220, height: 32) }
        if let saved = UserDefaults.standard.string(forKey: "collapsedFrame") {
            let frame = NSRectFromString(saved)
            if [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
               frame.width > 0, frame.height > 0 {
                collapsedFrame = frame
                naturalHandleSize = frame.size
            }
        }
        if UserDefaults.standard.object(forKey: "collapsedDocked") != nil {
            handleIsDocked = UserDefaults.standard.bool(forKey: "collapsedDocked")
        }
        if isCollapsed { showHandle() } else { panel.orderFrontRegardless() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Token Monitor")
        statusItem.button?.toolTip = "Codex 与 Claude Code 额度"
        let menu = NSMenu()
        menu.delegate = self
        let visibilityItem = menu.addItem(withTitle: "隐藏小窗口", action: #selector(togglePanel), keyEquivalent: "")
        visibilityItem.tag = 1
        let edgeItem = menu.addItem(withTitle: "收起到屏幕边缘", action: #selector(toggleEdge), keyEquivalent: "")
        edgeItem.tag = 2
        menu.addItem(withTitle: "立即同步", action: #selector(refresh), keyEquivalent: "r")
        let sourceItem = menu.addItem(withTitle: "Claude 读取方式", action: nil, keyEquivalent: "")
        sourceItem.tag = 3
        let sourceMenu = NSMenu()
        sourceMenu.delegate = self
        sourceMenu.addItem(withTitle: "主动查询（每分钟）", action: #selector(liveClaudeSource), keyEquivalent: "").tag = 31
        sourceMenu.addItem(withTitle: "状态栏推送", action: #selector(statusLineClaudeSource), keyEquivalent: "").tag = 32
        for item in sourceMenu.items { item.target = self }
        sourceItem.submenu = sourceMenu
        menu.addItem(withTitle: "启用终端 Claude 额度采集", action: #selector(connect), keyEquivalent: "")
        menu.addItem(withTitle: "登录终端 Claude Code", action: #selector(login), keyEquivalent: "").tag = 4
        menu.addItem(withTitle: "紧凑 / 完整显示", action: #selector(toggleCompact), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Token Monitor", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(instanceReopened(_:)),
            name: SingleInstanceLock.revealNotificationName, object: nil)
    }

    private func configure(_ window: NSPanel) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    private func screen(for frame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        let intersecting = screens.max { area(frame.intersection($0.visibleFrame)) < area(frame.intersection($1.visibleFrame)) }
        if let intersecting, area(frame.intersection(intersecting.visibleFrame)) > 0 { return intersecting }
        return screens.min { distance(frame, $0.visibleFrame) < distance(frame, $1.visibleFrame) }
    }

    private func area(_ frame: NSRect) -> CGFloat { frame.isNull ? 0 : max(0, frame.width) * max(0, frame.height) }
    private func distance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        return dx * dx + dy * dy
    }

    private func constrained(_ proposed: NSRect) -> NSRect {
        guard let available = screen(for: proposed)?.visibleFrame else { return proposed }
        return constrained(proposed, to: available)
    }

    private func constrained(_ proposed: NSRect, to available: NSRect) -> NSRect {
        var frame = proposed
        frame.size.width = min(frame.width, available.width)
        frame.size.height = min(frame.height, available.height)
        frame.origin.x = min(max(frame.origin.x, available.minX), available.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, available.minY), available.maxY - frame.height)
        return frame
    }

    private func setExpandedFrame(_ frame: NSRect) {
        expandedFrame = constrained(frame)
        isPositioning = true
        panel.setFrame(expandedFrame, display: true)
        panel.invalidateShadow()
        panel.saveFrame(usingName: "TokenMonitorFloatingPanel")
        isPositioning = false
    }

    private func resizeContent(to height: CGFloat) {
        guard panel != nil, height.isFinite, height > 0 else { return }
        naturalHeight = max(116, ceil(height))
        let available = screen(for: expandedFrame)?.visibleFrame
        let newHeight = min(naturalHeight, available?.height ?? naturalHeight)
        let newWidth = min(preferredWidth, available?.width ?? preferredWidth)
        guard abs(expandedFrame.height - newHeight) > 0.5 || expandedFrame.width != newWidth else { return }
        var frame = expandedFrame
        if edge == .right { frame.origin.x += frame.width - newWidth }
        else if edge == .top { frame.origin.x += (frame.width - newWidth) / 2 }
        frame.origin.y += frame.height - newHeight
        frame.size = NSSize(width: newWidth, height: newHeight)
        setExpandedFrame(frame)
    }

    private func handleFrame() -> NSRect? {
        let anchor = collapsedFrame ?? expandedFrame
        guard let available = screen(for: anchor)?.visibleFrame else { return nil }
        let size = NSSize(width: min(naturalHandleSize.width, available.width),
            height: min(naturalHandleSize.height, available.height))
        var frame = NSRect(x: edge == .top ? anchor.midX - size.width / 2 : anchor.minX,
            y: anchor.maxY - size.height, width: size.width, height: size.height)
        if handleIsDocked {
            switch edge {
            case .left: frame.origin.x = available.minX
            case .right: frame.origin.x = available.maxX - size.width
            case .top: frame.origin.y = available.maxY - size.height
            }
        }
        // Choose the display before resizing, so a wider horizontal summary
        // does not unexpectedly move itself to a neighboring display.
        return constrained(frame, to: available)
    }

    private func saveHandlePlacement() {
        guard let collapsedFrame else { return }
        UserDefaults.standard.set(NSStringFromRect(collapsedFrame), forKey: "collapsedFrame")
        UserDefaults.standard.set(handleIsDocked, forKey: "collapsedDocked")
        UserDefaults.standard.set(edge.rawValue, forKey: "edgeSide")
    }

    private func applyHandleFrame() {
        guard let frame = handleFrame() else { return }
        collapsedFrame = frame
        handle.setFrame(frame, display: handle.isVisible)
        handle.invalidateShadow()
        saveHandlePlacement()
    }

    private func resizeHandle(to size: CGSize) {
        guard handle != nil, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let next = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard abs(next.width - naturalHandleSize.width) > 0.5
                || abs(next.height - naturalHandleSize.height) > 0.5 else { return }
        naturalHandleSize = next
        // Defer geometry while a pointer gesture is in progress. Its mouse-up
        // callback applies the latest natural size using the actual drop frame.
        guard (handle as? FloatingQuotaPanel)?.isTrackingCollapsedInteraction != true else { return }
        applyHandleFrame()
    }

    private func positionHandle() {
        applyHandleFrame()
        guard let frame = collapsedFrame, renderedHandleEdge != edge || handle.contentView == nil else { return }
        renderedHandleEdge = edge
        handleViewGeneration += 1
        let generation = handleViewGeneration
        handle.contentView = FloatingWindowGlassView.hosting(
            EdgeHandleView(store: store, edge: edge,
                onExpand: { [weak self] in self?.expandFromEdge() },
                onDragEnded: { [weak self] in self?.finishHandleDrag() },
                onSizeChange: { [weak self] size in
                    DispatchQueue.main.async {
                        guard let self, self.handleViewGeneration == generation else { return }
                        self.resizeHandle(to: size)
                    }
                }),
            frame: NSRect(origin: .zero, size: frame.size), cornerRadius: 9)
        handle.invalidateShadow()
    }

    private func finishHandleDrag() {
        finishPanelTransition()
        let dropped = handle.frame
        guard let available = screen(for: dropped)?.visibleFrame else { return }
        let candidates: [(ScreenEdge, CGFloat)] = [
            (.top, abs(dropped.maxY - available.maxY)),
            (.left, abs(dropped.minX - available.minX)),
            (.right, abs(dropped.maxX - available.maxX))
        ]
        let near = candidates.filter { $0.1 <= 32 }.min { $0.1 < $1.1 }?.0
        collapsedFrame = constrained(dropped, to: available)
        handleIsDocked = near != nil
        if let near, near != edge {
            edge = near
            naturalHandleSize = edge == .top ? NSSize(width: 220, height: 32) : EdgeHandleView.size
        }
        // A free drop retains its current orientation and location. Only an
        // explicit near-edge drop changes docking/orientation.
        positionHandle()
    }

    private func expandedFrame(anchoredTo anchor: NSRect) -> NSRect {
        guard let available = screen(for: anchor)?.visibleFrame else { return expandedFrame }
        let size = NSSize(width: min(preferredWidth, available.width),
            height: min(naturalHeight, available.height))
        let x: CGFloat
        switch edge {
        case .left: x = anchor.minX
        case .right: x = anchor.maxX - size.width
        case .top: x = anchor.midX - size.width / 2
        }
        return constrained(NSRect(x: x, y: anchor.maxY - size.height,
            width: size.width, height: size.height), to: available)
    }

    private func prepareHandlePlacement(from frame: NSRect) {
        guard let available = screen(for: frame)?.visibleFrame else { return }
        // Keep a dragged mini's exact placement when the main window has not
        // moved. This also avoids drift when expansion must fit a screen edge.
        if let collapsedFrame {
            let expected = expandedFrame(anchoredTo: collapsedFrame)
            if abs(expected.minX - frame.minX) <= 1,
               abs(expected.maxY - frame.maxY) <= 1 { return }
        }
        let distances: [(ScreenEdge, CGFloat)] = [
            (.left, abs(frame.minX - available.minX)),
            (.right, abs(frame.maxX - available.maxX)),
            (.top, abs(frame.maxY - available.maxY))
        ]
        let nearest = distances.min { a, b in
            if abs(a.1 - b.1) < 0.5 { return a.0 == edge && b.0 != edge }
            return a.1 < b.1
        }
        let firstCollapse = collapsedFrame == nil
        if let nearest, firstCollapse || nearest.1 <= 32 {
            if edge != nearest.0 {
                edge = nearest.0
                naturalHandleSize = edge == .top ? NSSize(width: 220, height: 32) : EdgeHandleView.size
            }
            handleIsDocked = true
        } else {
            handleIsDocked = false
        }
        let x: CGFloat
        switch edge {
        case .left: x = frame.minX
        case .right: x = frame.maxX - naturalHandleSize.width
        case .top: x = frame.midX - naturalHandleSize.width / 2
        }
        collapsedFrame = NSRect(x: x, y: frame.maxY - naturalHandleSize.height,
            width: naturalHandleSize.width, height: naturalHandleSize.height)
    }

    private func cancelPanelTransition() {
        transitionTimer?.invalidate()
        transitionTimer = nil
        transitionStep = nil
        transitionCompletion = nil
        panel?.ignoresMouseEvents = false
        handle?.ignoresMouseEvents = false
    }

    private func finishPanelTransition() {
        let completion = transitionCompletion
        cancelPanelTransition()
        completion?()
    }

    private func show(_ incoming: NSPanel, hiding outgoing: NSPanel, animated: Bool) {
        // Only opacity changes: both windows retain their natural content size,
        // so text is never scaled or clipped during the transition.
        cancelPanelTransition()
        let shouldAnimate = animated && outgoing.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let initialIncomingAlpha = incoming.isVisible ? incoming.alphaValue : 0
        let initialOutgoingAlpha = outgoing.alphaValue
        incoming.alphaValue = shouldAnimate ? initialIncomingAlpha : 1
        incoming.ignoresMouseEvents = false
        incoming.orderFrontRegardless()
        let complete: () -> Void = {
            outgoing.orderOut(nil)
            outgoing.alphaValue = 1
            outgoing.ignoresMouseEvents = false
            incoming.alphaValue = 1
            incoming.ignoresMouseEvents = false
        }
        guard shouldAnimate else { complete(); return }
        outgoing.ignoresMouseEvents = true
        transitionStartedAt = ProcessInfo.processInfo.systemUptime
        transitionStep = { progress in
            incoming.alphaValue = initialIncomingAlpha + (1 - initialIncomingAlpha) * progress
            outgoing.alphaValue = initialOutgoingAlpha * (1 - progress)
        }
        transitionCompletion = complete
        let timer = Timer(timeInterval: 1.0 / 60, target: self,
            selector: #selector(advancePanelTransition(_:)), userInfo: nil, repeats: true)
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func advancePanelTransition(_ timer: Timer) {
        guard timer === transitionTimer else { timer.invalidate(); return }
        let progress = min(1, max(0, (ProcessInfo.processInfo.systemUptime - transitionStartedAt) / 0.2))
        let eased = progress * progress * (3 - 2 * progress)
        transitionStep?(CGFloat(eased))
        if progress >= 1 { finishPanelTransition() }
    }

    private func showHandle(animated: Bool = false) {
        positionHandle()
        show(handle, hiding: panel, animated: animated)
    }

    private func expandFromEdge() {
        guard isCollapsed else { revealExisting(); return }
        let anchor = handle.isVisible ? handle.frame : (collapsedFrame ?? expandedFrame)
        isCollapsed = false
        UserDefaults.standard.set(false, forKey: "edgeCollapsed")
        setExpandedFrame(expandedFrame(anchoredTo: anchor))
        show(panel, hiding: handle, animated: true)
    }

    private func hidePanels() {
        cancelPanelTransition()
        panel.orderOut(nil)
        handle.orderOut(nil)
        panel.alphaValue = 1
        handle.alphaValue = 1
    }

    @objc private func togglePanel() {
        if panel.isVisible || handle.isVisible { hidePanels() }
        else if isCollapsed { showHandle() }
        else { setExpandedFrame(expandedFrame); show(panel, hiding: handle, animated: false) }
    }

    @objc private func toggleEdge() {
        if isCollapsed { expandFromEdge(); return }
        setExpandedFrame(panel.frame)
        prepareHandlePlacement(from: expandedFrame)
        isCollapsed = true
        UserDefaults.standard.set(true, forKey: "edgeCollapsed")
        UserDefaults.standard.set(edge.rawValue, forKey: "edgeSide")
        showHandle(animated: true)
    }

    @objc private func screensChanged() {
        finishPanelTransition()
        var frame = expandedFrame
        if let available = screen(for: frame)?.visibleFrame {
            let height = min(naturalHeight, available.height)
            frame.origin.y += frame.height - height
            frame.size = NSSize(width: min(preferredWidth, available.width), height: height)
        }
        setExpandedFrame(frame)
        if collapsedFrame != nil { positionHandle() }
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel, !isPositioning, !isCollapsed else { return }
        expandedFrame = panel.frame
        panel.saveFrame(usingName: "TokenMonitorFloatingPanel")
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: 1)?.title = panel.isVisible || handle.isVisible ? "隐藏小窗口" : "显示小窗口"
        menu.item(withTag: 2)?.title = isCollapsed ? "展开小窗口" : "收起到屏幕边缘"
        menu.item(withTag: 3)?.title = store.claudeUsesStatusLine ? "Claude 读取方式：状态栏推送" : "Claude 读取方式：主动查询"
        menu.item(withTag: 31)?.state = store.claudeUsesStatusLine ? .off : .on
        menu.item(withTag: 32)?.state = store.claudeUsesStatusLine ? .on : .off
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { revealExisting() }
        return true
    }

    @objc private func instanceReopened(_ notification: Notification) { revealExisting() }

    private func revealExisting() {
        if isCollapsed { showHandle() }
        else { setExpandedFrame(expandedFrame); show(panel, hiding: handle, animated: false) }
    }

    @objc private func refresh() { store.refreshNow(force: true) }
    @objc private func connect() { store.connectClaude() }
    @objc private func login() { store.loginClaude() }
    @objc private func liveClaudeSource() { store.useClaudeStatusLine(false) }
    @objc private func statusLineClaudeSource() { store.useClaudeStatusLine(true) }
    @objc private func toggleCompact() {
        store.compact.toggle()
        UserDefaults.standard.set(store.compact, forKey: "compact")
        resizeContent(to: naturalHeight)
    }
    @objc private func quit() { hidePanels(); store.stop(); NSApplication.shared.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        cancelPanelTransition()
        if panel != nil { panel.saveFrame(usingName: "TokenMonitorFloatingPanel") }
        saveHandlePlacement()
        store?.stop()
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
