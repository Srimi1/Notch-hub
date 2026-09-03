/// Filters transient hover events while AppKit is resizing the overlay.
///
/// Resizing rebuilds tracking regions and can emit an exit without a matching
/// enter while the pointer has not moved. Controllers reconcile against the
/// settled panel frame when an animation completes.
public struct NotchHoverGate: Sendable, Equatable {
    public private(set) var isFrameAnimating = false
    public private(set) var isHovered = false

    public init() {}

    public mutating func beginFrameAnimation() {
        isFrameAnimating = true
    }

    public mutating func handleTransient(_ hovering: Bool) -> Bool? {
        guard !isFrameAnimating else { return nil }
        return update(hovering)
    }

    public mutating func finishFrameAnimation(pointerIsInside: Bool) -> Bool? {
        isFrameAnimating = false
        return update(pointerIsInside)
    }

    private mutating func update(_ hovering: Bool) -> Bool? {
        guard isHovered != hovering else { return nil }
        isHovered = hovering
        return hovering
    }
}
