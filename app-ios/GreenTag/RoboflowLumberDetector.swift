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

struct RoboflowDebugDetection: Identifiable, Equatable {
    let id = UUID()
    let frame: CGRect
    let confidence: Double
    let className: String
    let accepted: Bool
    let reason: String
}

struct RoboflowDetectionResult {
    let acceptedLumber: [LumberDetection]
    let debugDetections: [RoboflowDebugDetection]
}

struct RoboflowDebugFrame {
    let image: UIImage
    let detections: [RoboflowDebugDetection]
}

enum RoboflowLumberDetectorConfiguration {
    static let modelID = "lumber-v2-jrf2b"
    static let modelVersion = 4
    static let modelOutputThreshold = 0.05
    static let defaultMinimumConfidence = 0.50
}

@MainActor
final class RoboflowLumberDetector {
    private let roboflow: RoboflowMobile
    private let apiKey: String
    private var model: RFModel?
    private var usesHostedFallback = false

    init(apiKey: String) {
        self.apiKey = apiKey
        roboflow = RoboflowMobile(apiKey: apiKey)
    }

    var runtimeStatus: String {
        usesHostedFallback ? "Roboflow hosted" : "Roboflow on-device"
    }

    func prepareModel() async throws {
        guard model == nil, !usesHostedFallback else { return }

        let (loadedModel, errorDescription) = await loadModel()
        if let errorDescription {
            print("Roboflow CoreML load failed; falling back to hosted inference: \(errorDescription)")
            usesHostedFallback = true
            return
        }

        guard let loadedModel else {
            print("Roboflow CoreML load failed; falling back to hosted inference: no_model")
            usesHostedFallback = true
            return
        }

        loadedModel.configure(
            threshold: RoboflowLumberDetectorConfiguration.modelOutputThreshold,
            overlap: 0.45,
            maxObjects: 20
        )
        model = loadedModel
    }

    func detectLumber(in image: UIImage, minimumConfidence: Double) async throws -> RoboflowDetectionResult {
        if usesHostedFallback {
            return try await detectHostedLumber(in: image, minimumConfidence: minimumConfidence)
        }

        guard let model else {
            throw DetectorError.modelNotPrepared
        }

        let (predictions, errorDescription) = await detect(image: image, using: model)
        if let errorDescription {
            throw DetectorError.inferenceFailed(errorDescription)
        }

        let rawPredictions = predictions ?? []
        print("Roboflow detections raw_count=\(rawPredictions.count)")

        var debugDetections: [RoboflowDebugDetection] = []
        let lumberDetections: [LumberDetection] = rawPredictions.compactMap { prediction in
            guard let object = prediction as? RFObjectDetectionPrediction else {
                print("Roboflow detection unsupported_prediction=\(type(of: prediction))")
                return nil
            }

            let normalizedClass = object.className
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard normalizedClass == "lumber" else {
                printDetection(object, accepted: false, reason: "not_lumber")
                debugDetections.append(debugDetection(from: object, accepted: false, reason: "not_lumber"))
                return nil
            }

            guard Double(object.confidence) >= minimumConfidence else {
                printDetection(object, accepted: false, reason: "below_threshold")
                debugDetections.append(debugDetection(from: object, accepted: false, reason: "below_threshold"))
                return nil
            }

            printDetection(object, accepted: true, reason: "accepted")
            debugDetections.append(debugDetection(from: object, accepted: true, reason: "accepted"))

            return LumberDetection(
                frame: object.box,
                confidence: Double(object.confidence),
                className: object.className
            )
        }

        print("Roboflow detections accepted_lumber_count=\(lumberDetections.count)")
        return RoboflowDetectionResult(acceptedLumber: lumberDetections, debugDetections: debugDetections)
    }

    private func detectHostedLumber(in image: UIImage, minimumConfidence: Double) async throws -> RoboflowDetectionResult {
        guard let imageData = image.jpegData(compressionQuality: 0.72) else {
            throw DetectorError.inferenceFailed("Could not encode AR frame as JPEG.")
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "detect.roboflow.com"
        components.path = "/\(RoboflowLumberDetectorConfiguration.modelID)/\(RoboflowLumberDetectorConfiguration.modelVersion)"
        components.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "confidence", value: "5"),
            URLQueryItem(name: "overlap", value: "45"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "name", value: "arkit-frame.jpg")
        ]

        guard let url = components.url else {
            throw DetectorError.inferenceFailed("Could not construct Roboflow hosted URL.")
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = imageData.base64EncodedData()

        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("Roboflow hosted inference failed status=\(statusCode) body=\(body)")
            throw DetectorError.inferenceFailed("Hosted inference HTTP \(statusCode).")
        }

        let hostedResponse = try JSONDecoder().decode(HostedDetectionResponse.self, from: data)
        print("Roboflow hosted detections raw_count=\(hostedResponse.predictions.count)")

        var debugDetections: [RoboflowDebugDetection] = []
        let lumberDetections: [LumberDetection] = hostedResponse.predictions.compactMap { prediction in
            let normalizedClass = prediction.className
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let frame = CGRect(
                x: prediction.x - prediction.width / 2,
                y: prediction.y - prediction.height / 2,
                width: prediction.width,
                height: prediction.height
            )

            guard normalizedClass == "lumber" else {
                printHostedDetection(prediction, frame: frame, accepted: false, reason: "not_lumber")
                debugDetections.append(debugDetection(from: prediction, frame: frame, accepted: false, reason: "not_lumber"))
                return nil
            }

            guard prediction.confidence >= minimumConfidence else {
                printHostedDetection(prediction, frame: frame, accepted: false, reason: "below_threshold")
                debugDetections.append(debugDetection(from: prediction, frame: frame, accepted: false, reason: "below_threshold"))
                return nil
            }

            printHostedDetection(prediction, frame: frame, accepted: true, reason: "accepted")
            debugDetections.append(debugDetection(from: prediction, frame: frame, accepted: true, reason: "accepted"))

            return LumberDetection(
                frame: frame,
                confidence: prediction.confidence,
                className: prediction.className
            )
        }

        print("Roboflow hosted detections accepted_lumber_count=\(lumberDetections.count)")
        return RoboflowDetectionResult(acceptedLumber: lumberDetections, debugDetections: debugDetections)
    }

    private func printDetection(_ object: RFObjectDetectionPrediction, accepted: Bool, reason: String) {
        print(
            String(
                format: "Roboflow detection class=%@ confidence=%.3f accepted=%@ reason=%@ box=(x: %.1f, y: %.1f, w: %.1f, h: %.1f)",
                object.className,
                Double(object.confidence),
                accepted ? "true" : "false",
                reason,
                object.box.origin.x,
                object.box.origin.y,
                object.box.size.width,
                object.box.size.height
            )
        )
    }

    private func debugDetection(
        from object: RFObjectDetectionPrediction,
        accepted: Bool,
        reason: String
    ) -> RoboflowDebugDetection {
        RoboflowDebugDetection(
            frame: object.box,
            confidence: Double(object.confidence),
            className: object.className,
            accepted: accepted,
            reason: reason
        )
    }

    private func printHostedDetection(
        _ prediction: HostedPrediction,
        frame: CGRect,
        accepted: Bool,
        reason: String
    ) {
        print(
            String(
                format: "Roboflow hosted detection class=%@ confidence=%.3f accepted=%@ reason=%@ box=(x: %.1f, y: %.1f, w: %.1f, h: %.1f)",
                prediction.className,
                prediction.confidence,
                accepted ? "true" : "false",
                reason,
                frame.origin.x,
                frame.origin.y,
                frame.size.width,
                frame.size.height
            )
        )
    }

    private func debugDetection(
        from prediction: HostedPrediction,
        frame: CGRect,
        accepted: Bool,
        reason: String
    ) -> RoboflowDebugDetection {
        RoboflowDebugDetection(
            frame: frame,
            confidence: prediction.confidence,
            className: prediction.className,
            accepted: accepted,
            reason: reason
        )
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

private struct HostedDetectionResponse: Decodable {
    let predictions: [HostedPrediction]
}

private struct HostedPrediction: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let className: String
    let confidence: Double

    enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
        case className = "class"
        case confidence
    }
}
