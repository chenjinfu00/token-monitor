import SwiftUI
import AppKit
import QuartzCore

// The original brand outlines are documented in Design/BrandAssets/README.md.
// Native paths preserve the transparent cutouts and stay sharp at every scale.
enum ProviderBrand {
    case codex, claude

    var color: Color {
        switch self {
        case .codex: return .primary
        case .claude: return .claudeBrandOrange
        }
    }
}

private struct ProviderActivityEnvironmentKey: EnvironmentKey {
    static let defaultValue: ProviderActivityStore? = nil
}

extension EnvironmentValues {
    var providerActivityStore: ProviderActivityStore? {
        get { self[ProviderActivityEnvironmentKey.self] }
        set { self[ProviderActivityEnvironmentKey.self] = newValue }
    }
}

struct ProviderBrandIcon: View {
    let brand: ProviderBrand
    @Environment(\.providerActivityStore) private var activityStore

    var body: some View {
        Group {
            if let activityStore {
                ObservedProviderBrandIcon(brand: brand, activityStore: activityStore)
            } else {
                ProviderBrandShape(brand: brand)
                    .fill(brand.color, style: FillStyle(eoFill: false, antialiased: true))
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ObservedProviderBrandIcon: View {
    let brand: ProviderBrand
    @ObservedObject var activityStore: ProviderActivityStore

    var body: some View {
        let activity = activityStore.state(for: brand)
        NativeProviderBrandIcon(brand: brand, rotationDuration: activity.rotationDuration)
            .help(activity.helpText)
    }
}

private struct NativeProviderBrandIcon: NSViewRepresentable {
    let brand: ProviderBrand
    let rotationDuration: TimeInterval?

    func makeNSView(context: Context) -> ProviderBrandLayerView {
        ProviderBrandLayerView(brand: brand)
    }

    func updateNSView(_ view: ProviderBrandLayerView, context: Context) {
        view.configure(brand: brand, rotationDuration: rotationDuration)
    }

    static func dismantleNSView(_ view: ProviderBrandLayerView, coordinator: ()) {
        view.disconnect()
    }
}

// This clock is shared only by the two small brand layers. Changing speed preserves
// their phase; nothing here schedules work between activity/visibility changes.
@MainActor
private final class ProviderBrandRotationClock {
    struct Phase {
        var angle: Double = 0
        var time: CFTimeInterval = CACurrentMediaTime()
        var duration: TimeInterval?

        func angle(at time: CFTimeInterval) -> Double {
            guard let duration else { return angle }
            return angle - (time - self.time) / duration * 2 * .pi
        }
    }

    static let shared = ProviderBrandRotationClock()
    private var phases: [ProviderBrand: Phase] = [:]

    func reset(for brand: ProviderBrand) {
        phases.removeValue(forKey: brand)
    }

    func phase(for brand: ProviderBrand, duration: TimeInterval, at now: CFTimeInterval) -> Double {
        var phase = phases[brand] ?? Phase(time: now)
        if phase.duration != duration {
            phase.angle = phase.angle(at: now).truncatingRemainder(dividingBy: 2 * .pi)
            phase.time = now
            phase.duration = duration
            phases[brand] = phase
        }
        return phase.angle(at: now).truncatingRemainder(dividingBy: 2 * .pi)
    }
}

// AppKit's unflipped layer coordinates point upward. The source paths point
// downward, so we flip their geometry once and rotate with negative z angles.
// Consequently the rotation is visually clockwise, including after a resize.
@MainActor
final class ProviderBrandLayerView: NSView {
    private let symbolLayer = CAShapeLayer()
    private var brand: ProviderBrand
    private var requestedDuration: TimeInterval?
    private var animatedDuration: TimeInterval?
    private var rotationStartAngle: Double = 0
    private var rotationStartTime: CFTimeInterval = 0
    private var windowObservers: [NSObjectProtocol] = []
    private var appearanceObserver: NSObjectProtocol?
    private var applicationObservers: [NSObjectProtocol] = []
    private static let animationKey = "providerActivityRotation"

    private final class WeakReference {
        weak var value: ProviderBrandLayerView?
        init(_ value: ProviderBrandLayerView) { self.value = value }
    }
    private static var diagnosticViews: [ObjectIdentifier: WeakReference] = [:]

    // Explicit read-only diagnostics: no timer, file output, titles or content.
    static func diagnosticSnapshots() -> [[String: Any]] {
        diagnosticViews = diagnosticViews.filter { $0.value.value != nil }
        return diagnosticViews.values.compactMap { $0.value?.diagnosticSnapshot() }
    }

    private func diagnosticSnapshot() -> [String: Any] {
        let rotation = symbolLayer.animation(forKey: Self.animationKey)
        let windowVisible = window?.isVisible == true
        let miniaturized = window?.isMiniaturized == true
        let occlusionVisible = window?.occlusionState.contains(.visible) == true
        let hiddenAncestor = isHiddenOrHasHiddenAncestor
        let appHidden = NSApp.isHidden
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let visible = windowVisible && !miniaturized && occlusionVisible && !hiddenAncestor && !appHidden
        let null = NSNull()
        return [
            "brand": brand == .codex ? "codex" : "claude",
            "requestedDuration": requestedDuration.map { $0 as Any } ?? null,
            "animatedDuration": animatedDuration.map { $0 as Any } ?? null,
            "hasRotationAnimation": rotation != nil,
            "rotationAnimationDuration": rotation.map { $0.duration as Any } ?? null,
            "hasReturnAnimation": symbolLayer.animation(forKey: "providerActivityReturn") != nil,
            "presentationAngleRadians": (symbolLayer.presentation()?.value(forKeyPath: "transform.rotation.z") as? NSNumber).map { $0.doubleValue as Any } ?? null,
            "modelAngleRadians": (symbolLayer.value(forKeyPath: "transform.rotation.z") as? NSNumber).map { $0.doubleValue as Any } ?? null,
            "windowNumber": window.map { $0.windowNumber as Any } ?? null,
            "windowVisible": windowVisible,
            "windowMiniaturized": miniaturized,
            "windowOcclusionVisible": occlusionVisible,
            "hasHiddenAncestor": hiddenAncestor,
            "appHidden": appHidden,
            "reduceMotion": reduceMotion,
            "canAnimate": visible && !reduceMotion,
            "width": Double(bounds.width),
            "height": Double(bounds.height),
            "visibleRectWidth": Double(visibleRect.width),
            "visibleRectHeight": Double(visibleRect.height),
            "layerSpeed": Double(symbolLayer.speed)
        ]
    }

    init(brand: ProviderBrand) {
        self.brand = brand
        super.init(frame: .zero)
        wantsLayer = true
        layer?.isGeometryFlipped = false
        layer?.masksToBounds = false
        symbolLayer.fillRule = .nonZero
        symbolLayer.isGeometryFlipped = false
        symbolLayer.masksToBounds = false
        symbolLayer.allowsEdgeAntialiasing = true
        layer?.addSublayer(symbolLayer)
        setAccessibilityElement(false)
        appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAnimation() }
        }
        for notification in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            applicationObservers.append(NotificationCenter.default.addObserver(
                forName: notification, object: nil, queue: .main
            ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateAnimation() }
        })
        }
        updateColor()
        Self.diagnosticViews = Self.diagnosticViews.filter { $0.value.value != nil }
        Self.diagnosticViews[ObjectIdentifier(self)] = WeakReference(self)
    }

    required init?(coder: NSCoder) { nil }

    // Buttons and the existing native drag regions retain ownership of clicks.
    // Because this view is never hit, a Button whose label is only this icon
    // has no hit area: give that label a .contentShape (see providerButton).
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        symbolLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let upright = ProviderBrandShape(brand: brand).path(in: symbolLayer.bounds).cgPath
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        symbolLayer.path = upright.copy(using: &flip)
        symbolLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        if let window {
            for notification in [NSWindow.didChangeOcclusionStateNotification,
                NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                NSWindow.didExposeNotification, NSWindow.willCloseNotification,
                NSWindow.didChangeBackingPropertiesNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(
                    forName: notification, object: window, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.needsLayout = true
                        self?.updateAnimation()
                    }
                })
            }
        }
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    func configure(brand: ProviderBrand, rotationDuration: TimeInterval?) {
        if self.brand != brand {
            stopAnimation(returnUpright: false)
            self.brand = brand
            needsLayout = true
            updateColor()
        }
        requestedDuration = rotationDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if requestedDuration == nil { ProviderBrandRotationClock.shared.reset(for: brand) }
        updateAnimation()
    }

    func disconnect() {
        Self.diagnosticViews.removeValue(forKey: ObjectIdentifier(self))
        requestedDuration = nil
        stopAnimation(returnUpright: false)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers.removeAll()
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.removeAll()
        if let appearanceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appearanceObserver)
            self.appearanceObserver = nil
        }
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        applicationObservers.forEach(NotificationCenter.default.removeObserver)
        if let appearanceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appearanceObserver)
        }
    }

    private func updateColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            symbolLayer.fillColor = (brand == .codex ? NSColor.labelColor : NSColor(brand.color)).cgColor
            CATransaction.commit()
        }
    }

    private func updateAnimation() {
        let visible = window?.isVisible == true && window?.isMiniaturized == false
            && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !NSApp.isHidden
        let animate = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animate, let duration = requestedDuration else {
            stopAnimation(returnUpright: animate && requestedDuration == nil)
            return
        }
        guard duration != animatedDuration || symbolLayer.animation(forKey: Self.animationKey) == nil else { return }
        let now = CACurrentMediaTime()
        let phase = ProviderBrandRotationClock.shared.phase(for: brand, duration: duration, at: now)
        rotationStartAngle = phase
        rotationStartTime = now
        animatedDuration = duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.removeAnimation(forKey: "providerActivityReturn")
        symbolLayer.setValue(phase, forKeyPath: "transform.rotation.z")
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = phase
        rotation.toValue = phase - 2 * .pi
        rotation.duration = duration
        rotation.beginTime = symbolLayer.convertTime(now, from: nil)
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        symbolLayer.add(rotation, forKey: Self.animationKey)
        CATransaction.commit()
    }

    private func stopAnimation(returnUpright: Bool) {
        guard let duration = animatedDuration else {
            if !returnUpright { symbolLayer.removeAnimation(forKey: "providerActivityReturn") }
            return
        }
        let angle = rotationStartAngle - (CACurrentMediaTime() - rotationStartTime) / duration * 2 * .pi
        let nearestAngle = atan2(sin(angle), cos(angle))
        animatedDuration = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        symbolLayer.removeAnimation(forKey: Self.animationKey)
        symbolLayer.setValue(0, forKeyPath: "transform.rotation.z")
        if returnUpright && abs(nearestAngle) > 0.001 {
            let settle = CABasicAnimation(keyPath: "transform.rotation.z")
            settle.fromValue = nearestAngle
            settle.toValue = 0
            settle.duration = 0.22
            settle.timingFunction = CAMediaTimingFunction(name: .easeOut)
            symbolLayer.add(settle, forKey: "providerActivityReturn")
        } else {
            symbolLayer.removeAnimation(forKey: "providerActivityReturn")
        }
        CATransaction.commit()
    }
}

struct ProviderBrandShape: Shape {
    let brand: ProviderBrand

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - 12 * scale, ty: rect.midY - 12 * scale)
        let original: CGPath
        switch brand {
        case .codex: original = BrandVectorPaths.codex
        case .claude: original = BrandVectorPaths.claude
        }
        return Path(original).applying(transform)
    }
}

private enum BrandVectorPaths {
    static let codex: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 9.20509, y: 8.76514))
        p.addLine(to: CGPoint(x: 9.20509, y: 6.50548))
        p.addCurve(to: CGPoint(x: 9.44293, y: 6.07733), control1: CGPoint(x: 9.20509, y: 6.31517), control2: CGPoint(x: 9.27649, y: 6.17237))
        p.addLine(to: CGPoint(x: 13.9861, y: 3.46091))
        p.addCurve(to: CGPoint(x: 16.103, y: 2.93772), control1: CGPoint(x: 14.6046, y: 3.10416), control2: CGPoint(x: 15.342, y: 2.93772))
        p.addCurve(to: CGPoint(x: 20.7651, y: 7.50457), control1: CGPoint(x: 18.9573, y: 2.93772), control2: CGPoint(x: 20.7651, y: 5.14986))
        p.addCurve(to: CGPoint(x: 20.7412, y: 8.05164), control1: CGPoint(x: 20.7651, y: 7.67101), control2: CGPoint(x: 20.7651, y: 7.86132))
        p.addLine(to: CGPoint(x: 16.0316, y: 5.29243))
        p.addCurve(to: CGPoint(x: 15.1753, y: 5.29243), control1: CGPoint(x: 15.7462, y: 5.12599), control2: CGPoint(x: 15.4607, y: 5.12599))
        p.addLine(to: CGPoint(x: 9.20509, y: 8.76514))
        p.closeSubpath()
        p.move(to: CGPoint(x: 19.8136, y: 17.566))
        p.addLine(to: CGPoint(x: 19.8136, y: 12.1665))
        p.addCurve(to: CGPoint(x: 19.3854, y: 11.4291), control1: CGPoint(x: 19.8136, y: 11.8334), control2: CGPoint(x: 19.6708, y: 11.5955))
        p.addLine(to: CGPoint(x: 13.4152, y: 7.95637))
        p.addLine(to: CGPoint(x: 15.3656, y: 6.83836))
        p.addCurve(to: CGPoint(x: 15.8413, y: 6.83836), control1: CGPoint(x: 15.5321, y: 6.74332), control2: CGPoint(x: 15.6749, y: 6.74332))
        p.addLine(to: CGPoint(x: 20.3845, y: 9.45477))
        p.addCurve(to: CGPoint(x: 22.5728, y: 13.4032), control1: CGPoint(x: 21.6928, y: 10.216), control2: CGPoint(x: 22.5728, y: 11.8334))
        p.addCurve(to: CGPoint(x: 19.8136, y: 17.5657), control1: CGPoint(x: 22.5728, y: 15.2108), control2: CGPoint(x: 21.5025, y: 16.8759))
        p.addLine(to: CGPoint(x: 19.8136, y: 17.566))
        p.closeSubpath()
        p.move(to: CGPoint(x: 7.80173, y: 12.8088))
        p.addLine(to: CGPoint(x: 5.8513, y: 11.6671))
        p.addCurve(to: CGPoint(x: 5.61346, y: 11.239), control1: CGPoint(x: 5.68486, y: 11.5721), control2: CGPoint(x: 5.61346, y: 11.4293))
        p.addLine(to: CGPoint(x: 5.61346, y: 6.00616))
        p.addCurve(to: CGPoint(x: 10.2042, y: 1.53436), control1: CGPoint(x: 5.61346, y: 3.46114), control2: CGPoint(x: 7.56389, y: 1.53436))
        p.addCurve(to: CGPoint(x: 12.9159, y: 2.46205), control1: CGPoint(x: 11.2033, y: 1.53436), control2: CGPoint(x: 12.1307, y: 1.86746))
        p.addLine(to: CGPoint(x: 8.2301, y: 5.17374))
        p.addCurve(to: CGPoint(x: 7.80196, y: 5.91112), control1: CGPoint(x: 7.94475, y: 5.34018), control2: CGPoint(x: 7.80196, y: 5.57801))
        p.addLine(to: CGPoint(x: 7.80196, y: 12.809))
        p.addLine(to: CGPoint(x: 7.80173, y: 12.8088))
        p.closeSubpath()
        p.move(to: CGPoint(x: 12, y: 15.2349))
        p.addLine(to: CGPoint(x: 9.20509, y: 13.6651))
        p.addLine(to: CGPoint(x: 9.20509, y: 10.3352))
        p.addLine(to: CGPoint(x: 12, y: 8.76537))
        p.addLine(to: CGPoint(x: 14.7947, y: 10.3352))
        p.addLine(to: CGPoint(x: 14.7947, y: 13.6651))
        p.addLine(to: CGPoint(x: 12, y: 15.2349))
        p.closeSubpath()
        p.move(to: CGPoint(x: 13.7958, y: 22.4659))
        p.addCurve(to: CGPoint(x: 11.0841, y: 21.5382), control1: CGPoint(x: 12.7967, y: 22.4659), control2: CGPoint(x: 11.8693, y: 22.1328))
        p.addLine(to: CGPoint(x: 15.7699, y: 18.8265))
        p.addCurve(to: CGPoint(x: 16.198, y: 18.0892), control1: CGPoint(x: 16.0553, y: 18.6601), control2: CGPoint(x: 16.198, y: 18.4223))
        p.addLine(to: CGPoint(x: 16.198, y: 11.1912))
        p.addLine(to: CGPoint(x: 18.1723, y: 12.3329))
        p.addCurve(to: CGPoint(x: 18.4102, y: 12.7611), control1: CGPoint(x: 18.3388, y: 12.4279), control2: CGPoint(x: 18.4102, y: 12.5707))
        p.addLine(to: CGPoint(x: 18.4102, y: 17.9939))
        p.addCurve(to: CGPoint(x: 13.7958, y: 22.4657), control1: CGPoint(x: 18.4102, y: 20.5389), control2: CGPoint(x: 16.4359, y: 22.4657))
        p.addLine(to: CGPoint(x: 13.7958, y: 22.4659))
        p.closeSubpath()
        p.move(to: CGPoint(x: 8.15848, y: 17.1617))
        p.addLine(to: CGPoint(x: 3.61528, y: 14.5453))
        p.addCurve(to: CGPoint(x: 1.42701, y: 10.5969), control1: CGPoint(x: 2.30696, y: 13.784), control2: CGPoint(x: 1.42701, y: 12.1667))
        p.addCurve(to: CGPoint(x: 4.20987, y: 6.43431), control1: CGPoint(x: 1.42701, y: 8.76537), control2: CGPoint(x: 2.52115, y: 7.12417))
        p.addLine(to: CGPoint(x: 4.20987, y: 11.8575))
        p.addCurve(to: CGPoint(x: 4.63802, y: 12.5948), control1: CGPoint(x: 4.20987, y: 12.1906), control2: CGPoint(x: 4.35266, y: 12.4284))
        p.addLine(to: CGPoint(x: 10.5846, y: 16.0437))
        p.addLine(to: CGPoint(x: 8.63415, y: 17.1617))
        p.addCurve(to: CGPoint(x: 8.15848, y: 17.1617), control1: CGPoint(x: 8.46771, y: 17.2567), control2: CGPoint(x: 8.32492, y: 17.2567))
        p.closeSubpath()
        p.move(to: CGPoint(x: 7.897, y: 21.0626))
        p.addCurve(to: CGPoint(x: 3.23488, y: 16.5432), control1: CGPoint(x: 5.20919, y: 21.0626), control2: CGPoint(x: 3.23488, y: 19.0407))
        p.addCurve(to: CGPoint(x: 3.2824, y: 15.9723), control1: CGPoint(x: 3.23488, y: 16.3529), control2: CGPoint(x: 3.25875, y: 16.1626))
        p.addLine(to: CGPoint(x: 7.96817, y: 18.684))
        p.addCurve(to: CGPoint(x: 8.82447, y: 18.684), control1: CGPoint(x: 8.25352, y: 18.8504), control2: CGPoint(x: 8.53911, y: 18.8504))
        p.addLine(to: CGPoint(x: 14.7947, y: 15.2351))
        p.addLine(to: CGPoint(x: 14.7947, y: 17.4948))
        p.addCurve(to: CGPoint(x: 14.5568, y: 17.9229), control1: CGPoint(x: 14.7947, y: 17.6851), control2: CGPoint(x: 14.7233, y: 17.8279))
        p.addLine(to: CGPoint(x: 10.0136, y: 20.5394))
        p.addCurve(to: CGPoint(x: 7.89677, y: 21.0626), control1: CGPoint(x: 9.39518, y: 20.8961), control2: CGPoint(x: 8.6578, y: 21.0626))
        p.addLine(to: CGPoint(x: 7.897, y: 21.0626))
        p.closeSubpath()
        p.move(to: CGPoint(x: 13.7958, y: 23.8929))
        p.addCurve(to: CGPoint(x: 19.6235, y: 19.1358), control1: CGPoint(x: 16.6739, y: 23.8929), control2: CGPoint(x: 19.0762, y: 21.8475))
        p.addCurve(to: CGPoint(x: 24, y: 13.4034), control1: CGPoint(x: 22.2874, y: 18.4459), control2: CGPoint(x: 24, y: 15.9484))
        p.addCurve(to: CGPoint(x: 22.002, y: 8.95546), control1: CGPoint(x: 24, y: 11.7383), control2: CGPoint(x: 23.2865, y: 10.121))
        p.addCurve(to: CGPoint(x: 22.1924, y: 7.45705), control1: CGPoint(x: 22.121, y: 8.45591), control2: CGPoint(x: 22.1924, y: 7.95637))
        p.addCurve(to: CGPoint(x: 16.2458, y: 1.51048), control1: CGPoint(x: 22.1924, y: 4.05573), control2: CGPoint(x: 19.4331, y: 1.51048))
        p.addCurve(to: CGPoint(x: 14.3668, y: 1.81971), control1: CGPoint(x: 15.6037, y: 1.51048), control2: CGPoint(x: 14.9852, y: 1.60553))
        p.addCurve(to: CGPoint(x: 10.2042, y: 0.107117), control1: CGPoint(x: 13.2963, y: 0.773101), control2: CGPoint(x: 11.8215, y: 0.107117))
        p.addCurve(to: CGPoint(x: 4.37653, y: 4.86428), control1: CGPoint(x: 7.32606, y: 0.107117), control2: CGPoint(x: 4.92383, y: 2.15259))
        p.addCurve(to: CGPoint(x: 0, y: 10.5967), control1: CGPoint(x: 1.7126, y: 5.55414), control2: CGPoint(x: 0, y: 8.05164))
        p.addCurve(to: CGPoint(x: 1.99795, y: 15.0446), control1: CGPoint(x: 0, y: 12.2617), control2: CGPoint(x: 0.713506, y: 13.8791))
        p.addCurve(to: CGPoint(x: 1.80764, y: 16.543), control1: CGPoint(x: 1.87904, y: 15.5441), control2: CGPoint(x: 1.80764, y: 16.0437))
        p.addCurve(to: CGPoint(x: 7.75421, y: 22.4896), control1: CGPoint(x: 1.80764, y: 19.9443), control2: CGPoint(x: 4.56685, y: 22.4896))
        p.addCurve(to: CGPoint(x: 9.63324, y: 22.1803), control1: CGPoint(x: 8.39632, y: 22.4896), control2: CGPoint(x: 9.01478, y: 22.3945))
        p.addCurve(to: CGPoint(x: 13.7958, y: 23.8929), control1: CGPoint(x: 10.7035, y: 23.2269), control2: CGPoint(x: 12.1783, y: 23.8929))
        p.closeSubpath()
        return p
    }()

    static let claude: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 11.376, y: 24))
        p.addLine(to: CGPoint(x: 10.776, y: 23.544))
        p.addLine(to: CGPoint(x: 10.44, y: 22.8))
        p.addLine(to: CGPoint(x: 10.776, y: 21.312))
        p.addLine(to: CGPoint(x: 11.16, y: 19.392))
        p.addLine(to: CGPoint(x: 11.472, y: 17.856))
        p.addLine(to: CGPoint(x: 11.76, y: 15.96))
        p.addLine(to: CGPoint(x: 11.928, y: 15.336))
        p.addLine(to: CGPoint(x: 11.904, y: 15.288))
        p.addLine(to: CGPoint(x: 11.784, y: 15.312))
        p.addLine(to: CGPoint(x: 10.344, y: 17.28))
        p.addLine(to: CGPoint(x: 8.16, y: 20.232))
        p.addLine(to: CGPoint(x: 6.432, y: 22.056))
        p.addLine(to: CGPoint(x: 6.024, y: 22.224))
        p.addLine(to: CGPoint(x: 5.304, y: 21.864))
        p.addLine(to: CGPoint(x: 5.376, y: 21.192))
        p.addLine(to: CGPoint(x: 5.784, y: 20.616))
        p.addLine(to: CGPoint(x: 8.16, y: 17.568))
        p.addLine(to: CGPoint(x: 9.6, y: 15.672))
        p.addLine(to: CGPoint(x: 10.536, y: 14.592))
        p.addLine(to: CGPoint(x: 10.512, y: 14.448))
        p.addLine(to: CGPoint(x: 10.464, y: 14.448))
        p.addLine(to: CGPoint(x: 4.128, y: 18.576))
        p.addLine(to: CGPoint(x: 3, y: 18.72))
        p.addLine(to: CGPoint(x: 2.496, y: 18.264))
        p.addLine(to: CGPoint(x: 2.568, y: 17.52))
        p.addLine(to: CGPoint(x: 2.808, y: 17.28))
        p.addLine(to: CGPoint(x: 4.704, y: 15.96))
        p.addLine(to: CGPoint(x: 9.432, y: 13.32))
        p.addLine(to: CGPoint(x: 9.504, y: 13.08))
        p.addLine(to: CGPoint(x: 9.432, y: 12.96))
        p.addLine(to: CGPoint(x: 9.192, y: 12.96))
        p.addLine(to: CGPoint(x: 8.4, y: 12.912))
        p.addLine(to: CGPoint(x: 5.712, y: 12.84))
        p.addLine(to: CGPoint(x: 3.384, y: 12.744))
        p.addLine(to: CGPoint(x: 1.104, y: 12.624))
        p.addLine(to: CGPoint(x: 0.528, y: 12.504))
        p.addLine(to: CGPoint(x: 0, y: 11.784))
        p.addLine(to: CGPoint(x: 0.048, y: 11.424))
        p.addLine(to: CGPoint(x: 0.528, y: 11.112))
        p.addLine(to: CGPoint(x: 1.224, y: 11.16))
        p.addLine(to: CGPoint(x: 2.736, y: 11.28))
        p.addLine(to: CGPoint(x: 5.016, y: 11.424))
        p.addLine(to: CGPoint(x: 6.672, y: 11.52))
        p.addLine(to: CGPoint(x: 9.12, y: 11.784))
        p.addLine(to: CGPoint(x: 9.504, y: 11.784))
        p.addLine(to: CGPoint(x: 9.552, y: 11.616))
        p.addLine(to: CGPoint(x: 9.432, y: 11.52))
        p.addLine(to: CGPoint(x: 9.336, y: 11.424))
        p.addLine(to: CGPoint(x: 6.96, y: 9.84))
        p.addLine(to: CGPoint(x: 4.416, y: 8.16))
        p.addLine(to: CGPoint(x: 3.072, y: 7.176))
        p.addLine(to: CGPoint(x: 2.352, y: 6.672))
        p.addLine(to: CGPoint(x: 1.992, y: 6.216))
        p.addLine(to: CGPoint(x: 1.848, y: 5.208))
        p.addLine(to: CGPoint(x: 2.496, y: 4.488))
        p.addLine(to: CGPoint(x: 3.384, y: 4.56))
        p.addLine(to: CGPoint(x: 3.6, y: 4.608))
        p.addLine(to: CGPoint(x: 4.488, y: 5.304))
        p.addLine(to: CGPoint(x: 6.384, y: 6.768))
        p.addLine(to: CGPoint(x: 8.88, y: 8.616))
        p.addLine(to: CGPoint(x: 9.24, y: 8.904))
        p.addLine(to: CGPoint(x: 9.408, y: 8.808))
        p.addLine(to: CGPoint(x: 9.408, y: 8.736))
        p.addLine(to: CGPoint(x: 9.24, y: 8.472))
        p.addLine(to: CGPoint(x: 7.896, y: 6.024))
        p.addLine(to: CGPoint(x: 6.456, y: 3.528))
        p.addLine(to: CGPoint(x: 5.808, y: 2.496))
        p.addLine(to: CGPoint(x: 5.64, y: 1.872))
        p.addCurve(to: CGPoint(x: 5.544, y: 1.152), control1: CGPoint(x: 5.576, y: 1.656), control2: CGPoint(x: 5.544, y: 1.416))
        p.addLine(to: CGPoint(x: 6.288, y: 0.144001))
        p.addLine(to: CGPoint(x: 6.696, y: 0))
        p.addLine(to: CGPoint(x: 7.704, y: 0.144001))
        p.addLine(to: CGPoint(x: 8.112, y: 0.504001))
        p.addLine(to: CGPoint(x: 8.736, y: 1.92))
        p.addLine(to: CGPoint(x: 9.72, y: 4.152))
        p.addLine(to: CGPoint(x: 11.28, y: 7.176))
        p.addLine(to: CGPoint(x: 11.736, y: 8.088))
        p.addLine(to: CGPoint(x: 11.976, y: 8.904))
        p.addLine(to: CGPoint(x: 12.072, y: 9.168))
        p.addLine(to: CGPoint(x: 12.24, y: 9.168))
        p.addLine(to: CGPoint(x: 12.24, y: 9.024))
        p.addLine(to: CGPoint(x: 12.36, y: 7.296))
        p.addLine(to: CGPoint(x: 12.6, y: 5.208))
        p.addLine(to: CGPoint(x: 12.84, y: 2.52))
        p.addLine(to: CGPoint(x: 12.912, y: 1.752))
        p.addLine(to: CGPoint(x: 13.296, y: 0.840001))
        p.addLine(to: CGPoint(x: 14.04, y: 0.360001))
        p.addLine(to: CGPoint(x: 14.616, y: 0.624001))
        p.addLine(to: CGPoint(x: 15.096, y: 1.32))
        p.addLine(to: CGPoint(x: 15.024, y: 1.752))
        p.addLine(to: CGPoint(x: 14.76, y: 3.6))
        p.addLine(to: CGPoint(x: 14.184, y: 6.504))
        p.addLine(to: CGPoint(x: 13.824, y: 8.472))
        p.addLine(to: CGPoint(x: 14.04, y: 8.472))
        p.addLine(to: CGPoint(x: 14.28, y: 8.208))
        p.addLine(to: CGPoint(x: 15.264, y: 6.912))
        p.addLine(to: CGPoint(x: 16.92, y: 4.848))
        p.addLine(to: CGPoint(x: 17.64, y: 4.032))
        p.addLine(to: CGPoint(x: 18.504, y: 3.12))
        p.addLine(to: CGPoint(x: 19.056, y: 2.688))
        p.addLine(to: CGPoint(x: 20.088, y: 2.688))
        p.addLine(to: CGPoint(x: 20.832, y: 3.816))
        p.addLine(to: CGPoint(x: 20.496, y: 4.992))
        p.addLine(to: CGPoint(x: 19.44, y: 6.336))
        p.addLine(to: CGPoint(x: 18.552, y: 7.464))
        p.addLine(to: CGPoint(x: 17.28, y: 9.168))
        p.addLine(to: CGPoint(x: 16.512, y: 10.536))
        p.addLine(to: CGPoint(x: 16.584, y: 10.632))
        p.addLine(to: CGPoint(x: 16.752, y: 10.632))
        p.addLine(to: CGPoint(x: 19.608, y: 10.008))
        p.addLine(to: CGPoint(x: 21.168, y: 9.744))
        p.addLine(to: CGPoint(x: 22.992, y: 9.432))
        p.addLine(to: CGPoint(x: 23.832, y: 9.816))
        p.addLine(to: CGPoint(x: 23.928, y: 10.2))
        p.addLine(to: CGPoint(x: 23.592, y: 11.016))
        p.addLine(to: CGPoint(x: 21.624, y: 11.496))
        p.addLine(to: CGPoint(x: 19.32, y: 11.952))
        p.addLine(to: CGPoint(x: 15.888, y: 12.768))
        p.addLine(to: CGPoint(x: 15.84, y: 12.792))
        p.addLine(to: CGPoint(x: 15.888, y: 12.864))
        p.addLine(to: CGPoint(x: 17.424, y: 13.008))
        p.addLine(to: CGPoint(x: 18.096, y: 13.056))
        p.addLine(to: CGPoint(x: 19.728, y: 13.056))
        p.addLine(to: CGPoint(x: 22.752, y: 13.272))
        p.addLine(to: CGPoint(x: 23.544, y: 13.8))
        p.addLine(to: CGPoint(x: 24, y: 14.424))
        p.addLine(to: CGPoint(x: 23.928, y: 14.928))
        p.addLine(to: CGPoint(x: 22.704, y: 15.528))
        p.addLine(to: CGPoint(x: 21.072, y: 15.144))
        p.addLine(to: CGPoint(x: 17.232, y: 14.232))
        p.addLine(to: CGPoint(x: 15.936, y: 13.92))
        p.addLine(to: CGPoint(x: 15.744, y: 13.92))
        p.addLine(to: CGPoint(x: 15.744, y: 14.016))
        p.addLine(to: CGPoint(x: 16.848, y: 15.096))
        p.addLine(to: CGPoint(x: 18.84, y: 16.896))
        p.addLine(to: CGPoint(x: 21.36, y: 19.224))
        p.addLine(to: CGPoint(x: 21.48, y: 19.8))
        p.addLine(to: CGPoint(x: 21.168, y: 20.28))
        p.addLine(to: CGPoint(x: 20.832, y: 20.232))
        p.addLine(to: CGPoint(x: 18.624, y: 18.552))
        p.addLine(to: CGPoint(x: 17.76, y: 17.808))
        p.addLine(to: CGPoint(x: 15.84, y: 16.2))
        p.addLine(to: CGPoint(x: 15.72, y: 16.2))
        p.addLine(to: CGPoint(x: 15.72, y: 16.368))
        p.addLine(to: CGPoint(x: 16.152, y: 17.016))
        p.addLine(to: CGPoint(x: 18.504, y: 20.544))
        p.addLine(to: CGPoint(x: 18.624, y: 21.624))
        p.addLine(to: CGPoint(x: 18.456, y: 21.96))
        p.addLine(to: CGPoint(x: 17.832, y: 22.176))
        p.addLine(to: CGPoint(x: 17.184, y: 22.056))
        p.addLine(to: CGPoint(x: 15.792, y: 20.136))
        p.addLine(to: CGPoint(x: 14.376, y: 17.952))
        p.addLine(to: CGPoint(x: 13.224, y: 16.008))
        p.addLine(to: CGPoint(x: 13.104, y: 16.104))
        p.addLine(to: CGPoint(x: 12.408, y: 23.352))
        p.addLine(to: CGPoint(x: 12.096, y: 23.712))
        p.addLine(to: CGPoint(x: 11.376, y: 24))
        p.closeSubpath()
        return p
    }()

}
