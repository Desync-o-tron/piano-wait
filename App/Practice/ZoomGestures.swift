import PianoWaitCore
import SwiftUI
import UIKit

extension View {
    /// Pinching zooms the keyboard viewport around the fingers. Each update applies only the change
    /// since the last one, so a pinch can combine with panning.
    func pinchToZoomKeyboard(session: PracticeSession, onActiveChange: @escaping (Bool) -> Void) -> some View {
        modifier(PinchToZoomKeyboard(session: session, onActiveChange: onActiveChange))
    }
}

private struct PinchToZoomKeyboard: ViewModifier {
    let session: PracticeSession
    let onActiveChange: (Bool) -> Void

    @GestureState private var appliedMagnification: CGFloat?

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                MagnifyGesture()
                    .updating($appliedMagnification) { value, applied, _ in
                        let step = value.magnification / (applied ?? 1)
                        applied = value.magnification
                        session.zoom.keyboard = session.zoom.keyboard.zoomed(by: step, anchor: value.startAnchor.x)
                    }
            )
            .onChange(of: appliedMagnification != nil) { _, isActive in
                onActiveChange(isActive)
            }
    }
}

/// Reports horizontal movement of two fingers, on views where one finger already does something.
struct TwoFingerPanGesture: UIGestureRecognizerRepresentable {
    let onActiveChange: (Bool) -> Void
    let onPan: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = 2
        recognizer.maximumNumberOfTouches = 2
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        switch recognizer.state {
        case .began:
            onActiveChange(true)
        case .changed:
            onPan(recognizer.translation(in: recognizer.view).x)
            recognizer.setTranslation(.zero, in: recognizer.view)
        case .ended, .cancelled, .failed:
            onActiveChange(false)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
