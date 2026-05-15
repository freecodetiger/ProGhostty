import ProGhosttyCore
import SwiftUI

@main
struct ProGhosttyApp: App {
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("ProGhostty") {
      RootView()
        .environmentObject(model)
        .frame(minWidth: 980, minHeight: 640)
    }
    Settings {
      SettingsView()
        .environmentObject(model)
    }
  }
}
