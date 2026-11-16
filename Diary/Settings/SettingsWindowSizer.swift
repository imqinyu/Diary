import AppKit
import SwiftUI

/// 窗口尺寸由 AppKit 管理，避免 SwiftUI 的内容尺寸约束抢先跳到动画终点。
struct SettingsWindowSizer: NSViewRepresentable {
    let contentHeight: CGFloat?
    let controller: SettingsWindowResizeController

    func makeNSView(context: Context) -> SettingsSizingView {
        SettingsSizingView(controller: controller)
    }

    func updateNSView(_ view: SettingsSizingView, context: Context) {
        view.contentHeight = contentHeight
        view.scheduleResize()
    }
}

final class SettingsSizingView: NSView {
    var contentHeight: CGFloat? {
        didSet {
            if contentHeight == nil { lastContentHeight = nil }
        }
    }
    private let controller: SettingsWindowResizeController
    private var resizeScheduled = false
    private var lastContentHeight: CGFloat?

    init(controller: SettingsWindowResizeController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastContentHeight = nil
        scheduleResize()
    }

    override func layout() {
        super.layout()
        if lastContentHeight == nil { scheduleResize() }
    }

    func scheduleResize() {
        guard !resizeScheduled else { return }
        resizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeScheduled = false
            self.resizeWindow()
        }
    }

    private func resizeWindow() {
        guard let window, let contentHeight, bounds.height > 0,
              contentHeight != lastContentHeight else { return }

        let target = SettingsWindowGeometry.targetFrame(
            current: window.frame,
            viewportHeight: bounds.height,
            contentHeight: contentHeight,
            screen: window.screen?.visibleFrame
        )
        lastContentHeight = contentHeight
        controller.resize(window: window, to: target)
    }
}

@MainActor
final class SettingsWindowResizeController {
    private weak var sizedWindow: NSWindow?

    func resize(window: NSWindow, to target: NSRect) {
        let isFirstSize = sizedWindow !== window
        sizedWindow = window
        // 设置窗口固定宽度，高度只跟随内容；长页面由 ScrollView 承接。
        window.styleMask.remove(.resizable)
        guard abs(target.height - window.frame.height) > 0.5
                || abs(target.minY - window.frame.minY) > 0.5 else { return }

        let animate = !isFirstSize && window.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(target, display: true, animate: animate)
    }
}

enum SettingsWindowGeometry {
    static func targetFrame(current: NSRect, viewportHeight: CGFloat, contentHeight: CGFloat, screen: NSRect?) -> NSRect {
        let chromeHeight = max(0, current.height - viewportHeight)
        let desiredHeight = ceil(contentHeight) + chromeHeight
        let maximumHeight = screen.map { max(1, $0.height - 24) } ?? desiredHeight
        let height = min(desiredHeight, maximumHeight)
        // 保留上边缘，与传统 macOS 偏好设置窗口的伸缩方式一致。
        let top = screen.map { min(current.maxY, $0.maxY) } ?? current.maxY
        let bottom = screen.map { max($0.minY, top - height) } ?? (top - height)
        return NSRect(x: current.minX, y: bottom, width: current.width, height: height)
    }
}
