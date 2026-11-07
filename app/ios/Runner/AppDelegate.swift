import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // iOS remote-only build: the `dsh/notify` channel is hand-written in this
    // target (NotifyPlugin.swift), not a pub plugin, so it registers here.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NotifyPlugin") {
      NotifyPlugin.register(with: registrar)
    }
  }
}
