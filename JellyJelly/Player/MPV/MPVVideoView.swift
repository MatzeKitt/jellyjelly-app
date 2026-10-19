import AppKit
import OpenGL.GL3
import QuartzCore

/// Hosts mpv's OpenGL output via the libmpv render API.
final class MPVVideoView: NSView {
    let glLayer: MPVOpenGLLayer

    init(lib: LibMPV) {
        glLayer = MPVOpenGLLayer(lib: lib)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        glLayer
    }

    override var isOpaque: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        glLayer.contentsScale = window?.backingScaleFactor ?? 2
        glLayer.requestRedraw()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        glLayer.requestRedraw()
    }
}

/// Renders on Core Animation's display thread whenever mpv reports a new frame.
final class MPVOpenGLLayer: CAOpenGLLayer {
    private let lib: LibMPV
    private let lock = NSRecursiveLock()
    // The layer owns its GL context so mpv's render context exists before a file loads;
    // without one, mpv's video output fails to initialize and playback is audio-only.
    private let pixelFormat: CGLPixelFormatObj
    private let cglContext: CGLContextObj
    private var mpv: OpaquePointer?
    private var renderContext: OpaquePointer?
    /// Guarded by `flagLock`, never by `lock`: mpv's update callback must not block.
    private let flagLock = NSLock()
    private var needsRender = true
    private var callbackBox: Unmanaged<MPVOpenGLLayer>?

    init(lib: LibMPV) {
        self.lib = lib
        pixelFormat = Self.makePixelFormat()
        var context: CGLContextObj?
        CGLCreateContext(pixelFormat, nil, &context)
        cglContext = context!
        var swapInterval: GLint = 1
        CGLSetParameter(cglContext, kCGLCPSwapInterval, &swapInterval)
        CGLEnable(cglContext, kCGLCEMPEngine)
        super.init()
        isAsynchronous = true
        isOpaque = true
        needsDisplayOnBoundsChange = true
        backgroundColor = NSColor.black.cgColor
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        let other = layer as! MPVOpenGLLayer
        lib = other.lib
        pixelFormat = CGLRetainPixelFormat(other.pixelFormat)
        cglContext = CGLRetainContext(other.cglContext)
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        CGLReleaseContext(cglContext)
        CGLReleasePixelFormat(pixelFormat)
    }

    private static func makePixelFormat() -> CGLPixelFormatObj {
        var attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
            kCGLPFAAccelerated,
            kCGLPFADoubleBuffer,
            kCGLPFAAllowOfflineRenderers,
            kCGLPFASupportsAutomaticGraphicsSwitching,
            _CGLPixelFormatAttribute(rawValue: 0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        if pixelFormat == nil {
            // Fall back to a software-capable format rather than failing outright.
            attributes = [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(UInt32(kCGLOGLPVersion_3_2_Core.rawValue)),
                          kCGLPFADoubleBuffer, _CGLPixelFormatAttribute(rawValue: 0)]
            CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        }
        return pixelFormat!
    }

    /// Connects an mpv instance and creates its render context immediately.
    func attach(_ handle: OpaquePointer) {
        lock.lock()
        defer { lock.unlock() }
        mpv = handle
        CGLLockContext(cglContext)
        CGLSetCurrentContext(cglContext)
        createRenderContext()
        CGLUnlockContext(cglContext)
        requestRedraw()
    }

    /// Frees the render context. Must run before the mpv handle is destroyed.
    func detach() {
        lock.lock()
        defer { lock.unlock() }
        if let renderContext {
            lib.renderContextSetUpdateCallback(renderContext, nil, nil)
            CGLLockContext(cglContext)
            CGLSetCurrentContext(cglContext)
            lib.renderContextFree(renderContext)
            CGLUnlockContext(cglContext)
        }
        renderContext = nil
        mpv = nil
        callbackBox?.release()
        callbackBox = nil
    }

    func requestRedraw() {
        flagLock.lock()
        needsRender = true
        flagLock.unlock()
    }

    private func consumeRedrawRequest() -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        let value = needsRender
        needsRender = false
        return value
    }

    // MARK: - CAOpenGLLayer

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(pixelFormat)
    }

    override func copyCGLContext(forPixelFormat pixelFormat: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(cglContext)
    }

    override func canDraw(inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime time: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?) -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return needsRender
    }

    override func draw(inCGLContext context: CGLContextObj, pixelFormat: CGLPixelFormatObj, forLayerTime time: CFTimeInterval, displayTime: UnsafePointer<CVTimeStamp>?) {
        lock.lock()
        defer { lock.unlock() }
        _ = consumeRedrawRequest()
        guard let renderContext else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            glFlush()
            return
        }
        _ = lib.renderContextUpdate(renderContext)

        var framebuffer: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
        var viewport: [GLint] = [0, 0, 0, 0]
        glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

        var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: Int32(viewport[2]), h: Int32(viewport[3]), internal_format: 0)
        var flipY: Int32 = 1
        // Core Animation already paces draws to the display; blocking here would stall its thread.
        var blockForTargetTime: Int32 = 0
        withUnsafeMutablePointer(to: &fbo) { fboPointer in
            withUnsafeMutablePointer(to: &flipY) { flipPointer in
                withUnsafeMutablePointer(to: &blockForTargetTime) { blockPointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, data: UnsafeMutableRawPointer(blockPointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    _ = lib.renderContextRender(renderContext, &params)
                }
            }
        }
        glFlush()
        lib.renderContextReportSwap(renderContext)
    }

    private func createRenderContext() {
        guard let mpv else {
            return
        }
        var initParams = mpv_opengl_init_params(get_proc_address: glProcAddress, get_proc_address_ctx: nil)
        let apiType = strdup("opengl")
        defer { free(apiType) }
        var context: OpaquePointer?
        let result = withUnsafeMutablePointer(to: &initParams) { initPointer in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPointer)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return lib.renderContextCreate(&context, mpv, &params)
        }
        guard result >= 0, let context else {
            NSLog("JellyJelly: mpv_render_context_create failed (%d)", result)
            return
        }
        renderContext = context
        let box = Unmanaged.passRetained(self)
        callbackBox = box
        lib.renderContextSetUpdateCallback(context, { userData in
            guard let userData else {
                return
            }
            Unmanaged<MPVOpenGLLayer>.fromOpaque(userData).takeUnretainedValue().requestRedraw()
        }, box.toOpaque())
    }
}

private func glProcAddress(_ context: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let name,
          let symbol = CFStringCreateWithCString(kCFAllocatorDefault, name, CFStringBuiltInEncodings.ASCII.rawValue),
          let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
    else {
        return nil
    }
    return CFBundleGetFunctionPointerForName(bundle, symbol)
}
