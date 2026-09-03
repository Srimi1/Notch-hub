import AppKit
import NotchHubCore

@main
@MainActor
enum NotchHubLiteMain {
    static func main() {
        let application = NSApplication.shared
        let controller = NotchHubApplicationController(edition: .lite)
        application.delegate = controller
        application.run()
        withExtendedLifetime(controller) {}
    }
}
