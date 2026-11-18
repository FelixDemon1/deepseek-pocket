import Foundation
import Vision
import CoreGraphics
import ImageIO

public enum VisionOCRError: LocalizedError, Sendable {
    case unreadableImage

    public var errorDescription: String? {
        "无法解析所选图片"
    }
}

/// 100% On-Device OCR powered by Apple Vision (`VNRecognizeTextRequest`).
/// Zero cloud upload, zero Google ML Kit SDK telemetry — lets text-only reasoning models (like DeepSeek R1) read screenshots & docs for free.
public struct VisionOCRService: Sendable {
    public init() {}

    public func extractText(from imageData: Data) async throws -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw VisionOCRError.unreadableImage
        }

        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            let lines = (request.results ?? []).compactMap { observation in
                observation.topCandidates(1).first?.string
            }
            return lines.joined(separator: "\n")
        }.value
    }
}
