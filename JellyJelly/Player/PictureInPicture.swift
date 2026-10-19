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
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
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
        contentView = container

        contentAspectRatio = NSSize(width: aspectRatio, height: 1)
        if setFrameUsingName(Self.frameName) {
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
                window?.performDrag(with: event)
            }
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
