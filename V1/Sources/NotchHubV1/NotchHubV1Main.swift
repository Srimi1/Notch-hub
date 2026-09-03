import AppKit

@main
@MainActor
enum NotchHubV1Main {
    static func main() {
        let application = NSApplication.shared
        let controller = NotchHubV1ApplicationDelegate()
        application.delegate = controller
        application.run()
        withExtendedLifetime(controller) {}
    }
}
