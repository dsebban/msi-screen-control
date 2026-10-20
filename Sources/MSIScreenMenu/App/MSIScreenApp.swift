import SwiftUI

@main
struct MSIScreenApp: App {
    @NSApplicationDelegateAdaptor(StatusItemController.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
