import Cocoa
import Darwin
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
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
