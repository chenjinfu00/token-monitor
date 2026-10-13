import SwiftUI

@MainActor
struct WindowControlBar<Accessory: View>: View {
    let onClose: () -> Void
    let onHide: () -> Void
    let onResize: () -> Void
    let onRefresh: () -> Void
    var isRefreshing = false
    var onDoubleClick: () -> Void = {}
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 4) {
            control("xmark", label: "退出", action: onClose)
            control("eye.slash", label: "隐藏", action: onHide)
            control("arrow.up.left.and.arrow.down.right", label: "切换窗口大小", action: onResize)
            control("arrow.clockwise", label: "刷新", action: onRefresh)
                .rotationEffect(.degrees(isRefreshing ? 180 : 0))
                .animation(.easeInOut(duration: 0.3), value: isRefreshing)
            Color.clear
                .frame(minWidth: 12, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .overlay(NativeWindowDragRegion(onDoubleClick: onDoubleClick))
            accessory()
        }
        .foregroundStyle(.secondary)
    }

    private func control(_ symbol: String, label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
