import SwiftUI
import UIKit

/// Tap anywhere that isn't a text input to put the keyboard away.
///
/// SwiftUI has no app-wide answer for this: a `TextField` keeps focus until
/// something resigns it, so tapping the background of a List, form or sheet did
/// nothing and the only way out was the Return key (and `TextEditor` has none).
/// One recognizer on the window covers every screen, sheets included.
///
/// `cancelsTouchesInView = false` keeps it invisible to everything else — rows,
/// buttons and swipe actions still get their touch; it only observes it. Touches
/// that land on a text input are ignored, so moving focus from one field to
/// another isn't fought.
enum KeyboardDismiss {
    private static let recognizer: UITapGestureRecognizer = {
        let tap = UITapGestureRecognizer(target: Handler.shared, action: #selector(Handler.tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = Handler.shared
        return tap
    }()

    /// Idempotent — safe to call from every `onAppear`.
    @MainActor
    static func install() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return }
        guard !(window.gestureRecognizers ?? []).contains(recognizer) else { return }
        window.addGestureRecognizer(recognizer)
    }

    private final class Handler: NSObject, UIGestureRecognizerDelegate {
        static let shared = Handler()

        @objc func tapped() {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                            to: nil, from: nil, for: nil)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            while let v = view {
                if v is UITextField || v is UITextView { return false }
                view = v.superview
            }
            return true
        }

        /// Never block or be blocked by the screen's own gestures.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
