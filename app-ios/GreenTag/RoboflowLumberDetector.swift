import CoreGraphics
import Foundation
import Roboflow
import UIKit

struct LumberDetection: Identifiable, Equatable {
    let id = UUID()
    let frame: CGRect
    let confidence: Double
    let className: String

    var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }
}

enum RoboflowLumberDetectorConfiguration {
    static let modelID = "lumber-v2-jrf2b"
    static let modelVersion = 4
    static let minimumConfidence = 0.80
}

@MainActor
final class RoboflowLumberDetector {
    private let roboflow: RoboflowMobile
    private var model: RFModel?

    init(apiKey: String) {
        roboflow = RoboflowMobile(apiKey: apiKey)
    }

    func prepareModel() async throws {
        guard model == nil else { return }

        let (loadedModel, errorDescription) = await loadModel()
        if let errorDescription {
            throw DetectorError.modelLoadFailed(errorDescription)
        }

        guard let loadedModel else {
            throw DetectorError.modelLoadFailed("Roboflow did not return a Core ML model.")
        }

        loadedModel.configure(
            threshold: RoboflowLumberDetectorConfiguration.minimumConfidence,
            overlap: 0.45,
            maxObjects: 8
        )
        model = loadedModel
    }

    func detectLumber(in image: UIImage) async throws -> [LumberDetection] {
        guard let model else {
            throw DetectorError.modelNotPrepared
        }

        let (predictions, errorDescription) = await detect(image: image, using: model)
        if let errorDescription {
            throw DetectorError.inferenceFailed(errorDescription)
        }

        return (predictions ?? []).compactMap { prediction in
            guard let object = prediction as? RFObjectDetectionPrediction else {
                return nil
            }

            let normalizedClass = object.className
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedClass == "lumber" else {
                return nil
            }

            guard Double(object.confidence) >= RoboflowLumberDetectorConfiguration.minimumConfidence else {
                return nil
            }

            return LumberDetection(
                frame: object.box,
                confidence: Double(object.confidence),
                className: object.className
            )
        }
    }

    private func loadModel() async -> (RFModel?, String?) {
        await withCheckedContinuation { continuation in
            roboflow.load(
                model: RoboflowLumberDetectorConfiguration.modelID,
                modelVersion: RoboflowLumberDetectorConfiguration.modelVersion
            ) { model, error, _, _ in
                continuation.resume(returning: (model, error?.localizedDescription))
            }
        }
    }

    private func detect(image: UIImage, using model: RFModel) async -> ([RFPrediction]?, String?) {
        await withCheckedContinuation { continuation in
            model.detect(image: image) { predictions, error in
                continuation.resume(returning: (predictions, error?.localizedDescription))
            }
        }
    }

    enum DetectorError: Error {
        case modelNotPrepared
        case modelLoadFailed(String)
        case inferenceFailed(String)
    }
}
