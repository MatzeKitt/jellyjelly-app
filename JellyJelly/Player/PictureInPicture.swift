import AppKit
import SwiftUI

/// A floating window that keeps the video playing on top while the main window is browsed.
///
/// It hosts the engine's own video view, so it works the same for AVPlayer and mpv.
final class PictureInPictureWindow: NSPanel {
    private static let frameName = "PictureInPicture"
    private static let defaultWidth: CGFloat = 480
    private static let margin: CGFloat = 20

    init(model: PlayerModel, app: AppModel, aspectRatio: CGFloat, on screen: NSScreen?) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultWidth / aspectRatio),
            // Not `.resizable`: the resize handles below replace the system's thin resize border.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow
        minSize = NSSize(width: 240, height: 120)

        // Rounded corners: the container clips everything, including the engine's video layer.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let hosting = FirstMouseHostingView(rootView: PictureInPictureRoot(model: model, app: app))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        let handles = ResizeHandlesView(frame: container.bounds)
        handles.autoresizingMask = [.width, .height]
        container.addSubview(handles)
        contentView = container

        contentAspectRatio = NSSize(width: aspectRatio, height: 1)
        // Forced, as AppKit otherwise only restores the position of a window that isn't `.resizable`.
        if setFrameUsingName(Self.frameName, force: true) {
            fit(aspectRatio: aspectRatio)
        } else if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            setFrameOrigin(NSPoint(x: visible.maxX - frame.width - Self.margin, y: visible.minY + Self.margin))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Matches the window to a new video's shape, keeping its width and the screen edge it sits at.
    func setVideoAspectRatio(_ aspectRatio: CGFloat) {
        contentAspectRatio = NSSize(width: aspectRatio, height: 1)
        fit(aspectRatio: aspectRatio)
    }

    private func fit(aspectRatio: CGFloat) {
        var frame = frame
        let height = (frame.width / aspectRatio).rounded()
        guard abs(height - frame.height) >= 1 else {
            return
        }
        // Grow away from the nearer screen edge so the window stays put in its corner.
        if let screen, frame.midY > screen.visibleFrame.midY {
            frame.origin.y = frame.maxY - height
        }
        frame.size.height = height
        setFrame(frame, display: true)
    }

    /// Moves the window with the mouse, then snaps it into the nearest corner unless ⌘ is held.
    func drag() {
        let start = frame.origin
        let startMouse = NSEvent.mouseLocation
        var moved = false
        trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { event, stop in
            guard let event else {
                return
            }
            let mouse = NSEvent.mouseLocation
            if event.type == .leftMouseDragged {
                setFrameOrigin(NSPoint(x: start.x + mouse.x - startMouse.x, y: start.y + mouse.y - startMouse.y))
                moved = true
                return
            }
            stop.pointee = true
            if moved, !event.modifierFlags.contains(.command) {
                // The screen under the mouse is where the window was dropped, even if it hangs over another one.
                snapToNearestCorner(on: NSScreen.screens.first { $0.frame.contains(mouse) })
            }
        }
    }

    /// Resizes the window from a handle, keeping the video's aspect ratio and the opposite side in place.
    func resize(from handle: ResizeHandle) {
        guard let visible = (screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        let start = frame
        let startMouse = NSEvent.mouseLocation
        let wasSnapped = snappedFrame(for: start, in: visible) == start
        let aspectRatio = contentAspectRatio.width / contentAspectRatio.height
        let bounds = visible.insetBy(dx: Self.margin, dy: Self.margin)
        let minWidth = max(minSize.width, minSize.height * aspectRatio)
        let maxWidth = max(minWidth, min(bounds.width, bounds.height * aspectRatio))
        handle.cursor.set()
        trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { event, stop in
            guard let event else {
                return
            }
            guard event.type == .leftMouseDragged else {
                stop.pointee = true
                // A window in a corner stays there, also when it was resized from the corner at the screen edge.
                if wasSnapped {
                    snapToNearestCorner(on: screen)
                }
                return
            }
            let mouse = NSEvent.mouseLocation
            let dx = (mouse.x - startMouse.x) * handle.horizontal
            let dy = (mouse.y - startMouse.y) * handle.vertical
            let widthFromX = start.width + dx
            let widthFromY = (start.height + dy) * aspectRatio
            var width = switch (handle.horizontal, handle.vertical) {
            case (0, _): widthFromY
            case (_, 0): widthFromX
            // Corners follow whichever axis the mouse moved further along.
            default: abs(widthFromX - start.width) >= abs(widthFromY - start.width) ? widthFromX : widthFromY
            }
            width = min(max(width, minWidth), maxWidth).rounded()
            let height = (width / aspectRatio).rounded()

            // An edge handle grows the window away from the screen edge it's closer to, like fit(aspectRatio:).
            let anchorsRight = handle.horizontal < 0 || (handle.horizontal == 0 && start.midX > visible.midX)
            let anchorsTop = handle.vertical < 0 || (handle.vertical == 0 && start.midY > visible.midY)
            setFrame(NSRect(
                x: anchorsRight ? start.maxX - width : start.minX,
                y: anchorsTop ? start.maxY - height : start.minY,
                width: width,
                height: height
            ), display: true)
            handle.cursor.set()
        }
    }

    private func snapToNearestCorner(on screen: NSScreen?) {
        guard let visible = (screen ?? self.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }
        let target = snappedFrame(for: frame, in: visible)
        guard target != frame else {
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(target, display: true)
        }
    }

    /// The frame moved into the corner of the visible screen area nearest to its center.
    private func snappedFrame(for frame: NSRect, in visible: NSRect) -> NSRect {
        let bounds = visible.insetBy(dx: Self.margin, dy: Self.margin)
        var frame = frame
        frame.origin.x = frame.midX < visible.midX ? bounds.minX : bounds.maxX - frame.width
        frame.origin.y = frame.midY < visible.midY ? bounds.minY : bounds.maxY - frame.height
        return frame
    }

    /// Remembers the position and size, then hides the window and releases its content.
    func dismiss() {
        saveFrame(usingName: Self.frameName)
        orderOut(nil)
        contentView = NSView()
    }
}

/// Lets the first click on a control work even while the floating window isn't key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// Reads the theme inside a view body, so the floating window follows theme changes.
private struct PictureInPictureRoot: View {
    var model: PlayerModel
    var app: AppModel

    var body: some View {
        PictureInPictureView(model: model)
            .environment(app)
            .environment(\.palette, app.settings.theme.palette)
            .preferredColorScheme(.dark)
    }
}

private struct PictureInPictureView: View {
    var model: PlayerModel

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                VideoSurface(engineView: model.isPictureInPicture ? model.engine?.videoView : nil)

                // Drag anywhere to move, double-click to return to the full player.
                WindowDragArea(onHover: { hovering = $0 }) {
                    model.exitPictureInPicture()
                }

                if let text = model.subtitleText {
                    subtitle(text, height: proxy.size.height)
                        .allowsHitTesting(false)
                }

                if model.isBuffering {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                        .padding(12)
                        .background(.black.opacity(0.45), in: Circle())
                        .allowsHitTesting(false)
                }

                controls
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
                    .animation(.easeInOut(duration: 0.18), value: hovering)

                if let segment = model.activeSegment {
                    Button {
                        model.skipActiveSegment()
                    } label: {
                        Label(segment.skipTitle, systemImage: "forward.fill")
                            .labelStyle(TrailingIconLabelStyle())
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.onAccent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(palette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Skip (S or Return)")
                    .padding(.trailing, 10)
                    .padding(.bottom, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: model.activeSegment?.id)
    }

    private var controls: some View {
        ZStack {
            Color.black.opacity(0.35)
                .allowsHitTesting(false)

            HStack(alignment: .top) {
                Button {
                    model.exitPictureInPicture()
                } label: {
                    Image(systemName: "pip.exit")
                }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .help("Back to Player (Esc)")
                Spacer()
                Button {
                    model.close()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .help("Close Player")
            }
            .padding(10)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(spacing: 22) {
                centerButton("gobackward.10", size: 18, help: "Back 10 Seconds (←)") { model.skip(by: -10) }
                centerButton(model.isPaused ? "play.fill" : "pause.fill", size: 28, help: model.isPaused ? "Play (Space)" : "Pause (Space)") {
                    model.togglePause()
                }
                centerButton("goforward.10", size: 18, help: "Forward 10 Seconds (→)") { model.skip(by: 10) }
            }

            progressBar
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
        }
    }

    private func centerButton(_ systemImage: String, size: CGFloat, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .frame(width: size + 16, height: size + 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var progressBar: some View {
        GeometryReader { proxy in
            let duration = max(model.duration, 0.001)
            let progress = min(1, max(0, model.position / duration))
            let buffered = min(1, max(0, (model.position + model.bufferedAhead) / duration))
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.2))
                Rectangle().fill(.white.opacity(0.35))
                    .frame(width: proxy.size.width * buffered)
                Rectangle().fill(palette.accent)
                    .frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 3)
    }

    private func subtitle(_ text: String, height: CGFloat) -> some View {
        Text(text)
            .font(.system(size: max(11, height * 0.055) * app.settings.subtitleScale, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black, radius: 2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

/// Moves the window on drag and reports hover, also while the app is in the background.
private struct WindowDragArea: NSViewRepresentable {
    var onHover: (Bool) -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DragView {
        DragView()
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.onHover = onHover
        view.onDoubleClick = onDoubleClick
    }

    final class DragView: NSView {
        var onHover: ((Bool) -> Void)?
        var onDoubleClick: (() -> Void)?

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
            } else {
                (window as? PictureInPictureWindow)?.drag()
            }
        }
    }
}

/// A corner or edge of the window that resizes it.
enum ResizeHandle: CaseIterable {
    // Corners first, as they overlap the edges.
    case topLeft, topRight, bottomLeft, bottomRight, top, bottom, left, right

    /// 1 if the handle moves the right edge, -1 if it moves the left edge, 0 if neither.
    var horizontal: CGFloat {
        switch self {
        case .left, .topLeft, .bottomLeft: -1
        case .right, .topRight, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    /// 1 if the handle moves the top edge, -1 if it moves the bottom edge, 0 if neither.
    var vertical: CGFloat {
        switch self {
        case .top, .topLeft, .topRight: 1
        case .bottom, .bottomLeft, .bottomRight: -1
        case .left, .right: 0
        }
    }

    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition = switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        }
        return .frameResize(position: position, directions: .all)
    }
}

/// Resizes the window from generous corner and edge zones and shows the matching cursor, also while the app is in the background.
///
/// It only takes mouse events inside these zones, everything else goes through to the content below.
private final class ResizeHandlesView: NSView {
    private static let cornerSize: CGFloat = 16
    private static let edgeSize: CGFloat = 6

    private var hoveredHandle: ResizeHandle?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        handle(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        for handle in ResizeHandle.allCases {
            addCursorRect(rect(for: handle), cursor: handle.cursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredHandle != nil {
            hoveredHandle = nil
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let handle = handle(at: convert(event.locationInWindow, from: nil)) else {
            return
        }
        (window as? PictureInPictureWindow)?.resize(from: handle)
    }

    /// Cursor rects only apply while the window is key, so the cursor is also set on every move.
    private func updateCursor(with event: NSEvent) {
        let handle = handle(at: convert(event.locationInWindow, from: nil))
        if let handle {
            handle.cursor.set()
        } else if hoveredHandle != nil {
            NSCursor.arrow.set()
        }
        hoveredHandle = handle
    }

    private func handle(at point: NSPoint) -> ResizeHandle? {
        ResizeHandle.allCases.first { rect(for: $0).contains(point) }
    }

    private func rect(for handle: ResizeHandle) -> NSRect {
        let corner = Self.cornerSize
        let edge = Self.edgeSize
        return switch handle {
        case .topLeft: NSRect(x: bounds.minX, y: bounds.maxY - corner, width: corner, height: corner)
        case .topRight: NSRect(x: bounds.maxX - corner, y: bounds.maxY - corner, width: corner, height: corner)
        case .bottomLeft: NSRect(x: bounds.minX, y: bounds.minY, width: corner, height: corner)
        case .bottomRight: NSRect(x: bounds.maxX - corner, y: bounds.minY, width: corner, height: corner)
        case .top: NSRect(x: bounds.minX, y: bounds.maxY - edge, width: bounds.width, height: edge)
        case .bottom: NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: edge)
        case .left: NSRect(x: bounds.minX, y: bounds.minY, width: edge, height: bounds.height)
        case .right: NSRect(x: bounds.maxX - edge, y: bounds.minY, width: edge, height: bounds.height)
        }
    }
}

extension MediaSegment {
    var skipTitle: String {
        switch type {
        case "Intro": String(localized: "Skip Intro")
        case "Outro": String(localized: "Skip Credits")
        case "Recap": String(localized: "Skip Recap")
        case "Preview": String(localized: "Skip Preview")
        case "Commercial": String(localized: "Skip Sponsor")
        default: String(localized: "Skip")
        }
    }
}
