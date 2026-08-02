import Foundation
import UIKit
import Vision

/// Wraps Vision's text recognition for photographed notes.
///
/// On-device and offline, mirroring `SpeechRecognizer`: nothing leaves the
/// phone until the finished capture is committed. The OCR text lands in the
/// same draft editor as dictation does, so a misread word can be fixed before
/// it ever reaches the vault.
@MainActor
final class TextRecognizer: ObservableObject {
    @Published var isRecognizing = false

    /// Read the text out of an image. Returns "" when there's nothing legible —
    /// which is a normal outcome (a photo of a whiteboard sketch, a diagram, a
    /// plant) and not an error. The photo is still worth capturing.
    func recognize(_ image: UIImage) async -> String {
        guard let cgImage = image.cgImage else { return "" }
        isRecognizing = true
        defer { isRecognizing = false }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // Alp captures in both languages, often on the same page.
                request.recognitionLanguages = ["en-US", "tr-TR"]

                let handler = VNImageRequestHandler(cgImage: cgImage,
                                                    orientation: orientation,
                                                    options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "")
                    return
                }

                // Vision returns observations in reading order, one per detected
                // line, so joining with newlines preserves the page's layout
                // well enough for a note.
                let lines = (request.results ?? []).compactMap {
                    $0.topCandidates(1).first?.string
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
