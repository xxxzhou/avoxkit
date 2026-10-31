import Cocoa
import Darwin
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // avox 插件用 -undefined dynamic_lookup，宿主必须先把 shim 送进全局符号表
    if let frameworks = Bundle.main.privateFrameworksPath {
      dlopen(frameworks + "/avoxkit_native.dylib", RTLD_NOW | RTLD_GLOBAL)
    }

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // 商店截图: 2x 屏下 content 1280x800 正好出 2560x1600 像素
    if let spec = ProcessInfo.processInfo.environment["AVOXKIT_WINDOW_SIZE"] {
      let parts = spec.split(separator: "x").compactMap { Double($0) }
      if parts.count == 2 {
        self.setContentSize(NSSize(width: parts[0], height: parts[1]))
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
