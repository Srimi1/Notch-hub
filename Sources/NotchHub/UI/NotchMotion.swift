import AppKit
import QuartzCore
import SwiftUI

/// The single source of truth for the notch's open and close motion.
///
/// The SwiftUI content and the AppKit window frame used to animate on two
/// different systems — a 0.28s ease-out on the window against a 0.35s spring on
/// the content — so the black box and the interface inside it settled on
/// different timelines. That mismatch is what read as a stutter as the panel
/// opened. Both now read their duration and curve from here, so they can never
/// drift apart again.
///
/// The feel is deliberately crisp: a short ease-out with no spring bounce.
enum NotchMotion {

    /// Ordinary open/close duration.
    static let duration: TimeInterval = 0.22

    /// Near-instant when the user has asked for reduced motion.
    static let reducedDuration: TimeInterval = 0.01

    /// The duration to use right now, honouring the Reduce Motion setting.
    static var currentDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? reducedDuration : duration
    }

    /// SwiftUI animation for content changes driven through `withAnimation`.
    static var swiftUI: Animation {
        .easeOut(duration: currentDuration)
    }

    /// The matching Core Animation curve for the window-frame animation, so the
    /// frame and the content share one easing as well as one duration.
    static let timingFunction = CAMediaTimingFunction(name: .easeOut)
}
