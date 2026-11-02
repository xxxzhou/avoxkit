import Cocoa
import Darwin
import FlutterMacOS
import StoreKit

@main
class AppDelegate: FlutterAppDelegate {
  private var reviewChannel: FlutterMethodChannel?

  override func applicationDidFinishLaunching(_ notification: Notification) {
    super.applicationDidFinishLaunching(notification)
    DispatchQueue.main.async {
      guard let window = NSApplication.shared.windows.first,
            let controller = window.contentViewController as? FlutterViewController else {
        return
      }
      let channel = FlutterMethodChannel(
        name: "dev.avox.avoxkit/review",
        binaryMessenger: controller.engine.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        if call.method == "request" {
          if #available(macOS 10.14, *) {
            SKStoreReviewController.requestReview()
          }
          result(nil)
        } else {
          result(FlutterMethodNotImplemented)
        }
      }
      self.reviewChannel = channel
    }
  }
  override func applicationWillTerminate(_ notification: Notification) {
    // 停任务/日志线程，避免退出竞态（与 Windows Runner 的 OnDestroy 一致）
    if let frameworks = Bundle.main.privateFrameworksPath,
       let handle = dlopen(
         frameworks + "/avoxkit_native.dylib", RTLD_NOW | RTLD_GLOBAL),
       let sym = dlsym(handle, "ak_shutdown") {
      typealias ShutdownFn = @convention(c) () -> Void
      unsafeBitCast(sym, to: ShutdownFn.self)()
    }
    super.applicationWillTerminate(notification)
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}
