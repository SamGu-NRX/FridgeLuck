// FLDesignSystem — Reduce motion.
//
// A first-class override for the system Reduce Motion preference. The
// system value is get-only in SwiftUI (its key path never forms a
// WritableKeyPath), so no test or preview can set it through
// .environment(_:,_:). Components read the composed value here: an
// explicit override when one is set, otherwise the real system setting,
// which keeps runtime behaviour unchanged for users.

#if canImport(UIKit) || canImport(AppKit)
import SwiftUI

private struct FLReduceMotionOverrideKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

public extension EnvironmentValues {
    /// Reduce motion for FridgeLuck components: an explicit override if
    /// set, otherwise the system setting.
    var flReduceMotion: Bool {
        get { self[FLReduceMotionOverrideKey.self] ?? accessibilityReduceMotion }
        set { self[FLReduceMotionOverrideKey.self] = newValue }
    }
}
#endif
