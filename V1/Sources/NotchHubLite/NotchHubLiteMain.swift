import AppKit

@main
@MainActor
enum NotchHubLiteMain {
    static func main() {
        let application = NSApplication.shared
        let controller = LiteApplicationController()
        application.delegate = controller
        application.run()
        withExtendedLifetime(controller) {}
    }
}
