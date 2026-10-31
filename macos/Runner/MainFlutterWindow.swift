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

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
