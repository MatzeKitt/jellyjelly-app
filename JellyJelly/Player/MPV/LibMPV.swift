import Foundation

/// libmpv, resolved at runtime with `dlopen`.
///
/// Loading lazily keeps mpv an optional dependency: without it the app still runs and
/// falls back to AVPlayer. Install it with `brew install mpv`, or bundle `libmpv.2.dylib`
/// in `JellyJelly.app/Contents/Frameworks`.
final class LibMPV: @unchecked Sendable {
    typealias Handle = OpaquePointer
    typealias WakeupCallback = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let create: @convention(c) () -> Handle?
    let initialize: @convention(c) (Handle?) -> Int32
    let terminateDestroy: @convention(c) (Handle?) -> Void
    let setOptionString: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let setPropertyString: @convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    let setProperty: @convention(c) (Handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    let getProperty: @convention(c) (Handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32
    let getPropertyString: @convention(c) (Handle?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    let free: @convention(c) (UnsafeMutableRawPointer?) -> Void
    let command: @convention(c) (Handle?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    let commandAsync: @convention(c) (Handle?, UInt64, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32
    let observeProperty: @convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, mpv_format) -> Int32
    let waitEvent: @convention(c) (Handle?, Double) -> UnsafeMutablePointer<mpv_event>?
    let setWakeupCallback: @convention(c) (Handle?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void
    let errorString: @convention(c) (Int32) -> UnsafePointer<CChar>?
    let clientAPIVersion: @convention(c) () -> UInt

    let renderContextCreate: @convention(c) (UnsafeMutablePointer<OpaquePointer?>?, Handle?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    let renderContextSetUpdateCallback: @convention(c) (OpaquePointer?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void
    let renderContextUpdate: @convention(c) (OpaquePointer?) -> UInt64
    let renderContextRender: @convention(c) (OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?) -> Int32
    let renderContextReportSwap: @convention(c) (OpaquePointer?) -> Void
    let renderContextFree: @convention(c) (OpaquePointer?) -> Void

    let path: String

    static let shared: LibMPV? = LibMPV.load()

    static var searchPaths: [String] {
        var paths: [String] = []
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append(frameworks + "/libmpv.2.dylib")
            paths.append(frameworks + "/libmpv.dylib")
        }
        paths += [
            "/opt/homebrew/lib/libmpv.2.dylib",
            "/opt/homebrew/lib/libmpv.dylib",
            "/usr/local/lib/libmpv.2.dylib",
            "/usr/local/lib/libmpv.dylib",
            "/opt/local/lib/libmpv.2.dylib",
        ]
        return paths
    }

    private static func load() -> LibMPV? {
        for path in searchPaths where FileManager.default.fileExists(atPath: path) {
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL), let lib = LibMPV(handle: handle, path: path) {
                return lib
            }
        }
        return nil
    }

    private init?(handle: UnsafeMutableRawPointer, path: String) {
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else {
                return nil
            }
            return unsafeBitCast(pointer, to: type)
        }
        guard
            let create = symbol("mpv_create", (@convention(c) () -> Handle?).self),
            let initialize = symbol("mpv_initialize", (@convention(c) (Handle?) -> Int32).self),
            let terminateDestroy = symbol("mpv_terminate_destroy", (@convention(c) (Handle?) -> Void).self),
            let setOptionString = symbol("mpv_set_option_string", (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self),
            let setPropertyString = symbol("mpv_set_property_string", (@convention(c) (Handle?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32).self),
            let setProperty = symbol("mpv_set_property", (@convention(c) (Handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32).self),
            let getProperty = symbol("mpv_get_property", (@convention(c) (Handle?, UnsafePointer<CChar>?, mpv_format, UnsafeMutableRawPointer?) -> Int32).self),
            let getPropertyString = symbol("mpv_get_property_string", (@convention(c) (Handle?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?).self),
            let free = symbol("mpv_free", (@convention(c) (UnsafeMutableRawPointer?) -> Void).self),
            let command = symbol("mpv_command", (@convention(c) (Handle?, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32).self),
            let commandAsync = symbol("mpv_command_async", (@convention(c) (Handle?, UInt64, UnsafeMutablePointer<UnsafePointer<CChar>?>?) -> Int32).self),
            let observeProperty = symbol("mpv_observe_property", (@convention(c) (Handle?, UInt64, UnsafePointer<CChar>?, mpv_format) -> Int32).self),
            let waitEvent = symbol("mpv_wait_event", (@convention(c) (Handle?, Double) -> UnsafeMutablePointer<mpv_event>?).self),
            let setWakeupCallback = symbol("mpv_set_wakeup_callback", (@convention(c) (Handle?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void).self),
            let errorString = symbol("mpv_error_string", (@convention(c) (Int32) -> UnsafePointer<CChar>?).self),
            let clientAPIVersion = symbol("mpv_client_api_version", (@convention(c) () -> UInt).self),
            let renderContextCreate = symbol("mpv_render_context_create", (@convention(c) (UnsafeMutablePointer<OpaquePointer?>?, Handle?, UnsafeMutablePointer<mpv_render_param>?) -> Int32).self),
            let renderContextSetUpdateCallback = symbol("mpv_render_context_set_update_callback", (@convention(c) (OpaquePointer?, WakeupCallback?, UnsafeMutableRawPointer?) -> Void).self),
            let renderContextUpdate = symbol("mpv_render_context_update", (@convention(c) (OpaquePointer?) -> UInt64).self),
            let renderContextRender = symbol("mpv_render_context_render", (@convention(c) (OpaquePointer?, UnsafeMutablePointer<mpv_render_param>?) -> Int32).self),
            let renderContextReportSwap = symbol("mpv_render_context_report_swap", (@convention(c) (OpaquePointer?) -> Void).self),
            let renderContextFree = symbol("mpv_render_context_free", (@convention(c) (OpaquePointer?) -> Void).self)
        else {
            return nil
        }
        // The client API major version must match the bundled headers (MPV_CLIENT_API_VERSION 2.x).
        guard clientAPIVersion() >> 16 == 2 else {
            return nil
        }
        self.create = create
        self.initialize = initialize
        self.terminateDestroy = terminateDestroy
        self.setOptionString = setOptionString
        self.setPropertyString = setPropertyString
        self.setProperty = setProperty
        self.getProperty = getProperty
        self.getPropertyString = getPropertyString
        self.free = free
        self.command = command
        self.commandAsync = commandAsync
        self.observeProperty = observeProperty
        self.waitEvent = waitEvent
        self.setWakeupCallback = setWakeupCallback
        self.errorString = errorString
        self.clientAPIVersion = clientAPIVersion
        self.renderContextCreate = renderContextCreate
        self.renderContextSetUpdateCallback = renderContextSetUpdateCallback
        self.renderContextUpdate = renderContextUpdate
        self.renderContextRender = renderContextRender
        self.renderContextReportSwap = renderContextReportSwap
        self.renderContextFree = renderContextFree
        self.path = path
    }

    // MARK: - Swift conveniences

    @discardableResult
    func setOption(_ handle: Handle?, _ name: String, _ value: String) -> Int32 {
        setOptionString(handle, name, value)
    }

    @discardableResult
    func set(_ handle: Handle?, _ name: String, _ value: String) -> Int32 {
        setPropertyString(handle, name, value)
    }

    func string(_ handle: Handle?, _ name: String) -> String? {
        guard let raw = getPropertyString(handle, name) else {
            return nil
        }
        defer { free(raw) }
        return String(cString: raw)
    }

    func double(_ handle: Handle?, _ name: String) -> Double? {
        var value = 0.0
        return getProperty(handle, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    func int(_ handle: Handle?, _ name: String) -> Int64? {
        var value: Int64 = 0
        return getProperty(handle, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    func flag(_ handle: Handle?, _ name: String) -> Bool? {
        var value: Int32 = 0
        return getProperty(handle, name, MPV_FORMAT_FLAG, &value) >= 0 ? value != 0 : nil
    }

    @discardableResult
    func command(_ handle: Handle?, _ args: [String], async: Bool = false) -> Int32 {
        let cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { Foundation.free($0) } }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }
        pointers.append(nil)
        return pointers.withUnsafeMutableBufferPointer { buffer in
            async ? commandAsync(handle, 0, buffer.baseAddress) : command(handle, buffer.baseAddress)
        }
    }

    var version: String {
        let raw = clientAPIVersion()
        return "\(raw >> 16).\(raw & 0xFFFF)"
    }
}
