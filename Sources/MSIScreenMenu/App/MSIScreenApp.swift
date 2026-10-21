import SwiftUI

@main
struct MSIScreenApp: App {
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var delegate

    var body: some Scene {
        Settings {
            AppSettingsView(settings: delegate.appSettings)
                .padding(24)
                .frame(width: 420)
        }
    }
}
