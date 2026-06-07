import ARKit
import CoreImage
import RealityKit
import SwiftUI
import UIKit

struct ARInspectionView: UIViewRepresentable {
    let roboflowAPIKey: String
    let minimumConfidence: Double
    let onMeasurementUpdated: (Double, Double) -> Void
    let onDetectionsUpdated: ([LumberDetection]) -> Void
    let onDebugFrameUpdated: (RoboflowDebugFrame) -> Void
    let onDetectorStatusUpdated: (String) -> Void

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        context.coordinator.arView = arView

        guard ARWorldTrackingConfiguration.isSupported else {
            return arView
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.environmentTexturing = .automatic
        arView.session.run(configuration)
        context.coordinator.startMeasuring()

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.update(apiKey: roboflowAPIKey, minimumConfidence: minimumConfidence)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            roboflowAPIKey: roboflowAPIKey,
            minimumConfidence: minimumConfidence,
            onMeasurementUpdated: onMeasurementUpdated,
            onDetectionsUpdated: onDetectionsUpdated,
            onDebugFrameUpdated: onDebugFrameUpdated,
            onDetectorStatusUpdated: onDetectorStatusUpdated
        )
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.stopMeasuring()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var arView: ARView?

        private var roboflowAPIKey: String
        private var minimumConfidence: Double
        private let onMeasurementUpdated: (Double, Double) -> Void
        private let onDetectionsUpdated: ([LumberDetection]) -> Void
        private let onDebugFrameUpdated: (RoboflowDebugFrame) -> Void
        private let onDetectorStatusUpdated: (String) -> Void
        private let imageContext = CIContext()
        private var detector: RoboflowLumberDetector?
        private var screenDetections: [LumberDetection] = []
        private var isDetecting = false
        private var displayLink: CADisplayLink?
        private var tick = 0

        init(
            roboflowAPIKey: String,
            minimumConfidence: Double,
            onMeasurementUpdated: @escaping (Double, Double) -> Void,
            onDetectionsUpdated: @escaping ([LumberDetection]) -> Void,
            onDebugFrameUpdated: @escaping (RoboflowDebugFrame) -> Void,
            onDetectorStatusUpdated: @escaping (String) -> Void
        ) {
            self.roboflowAPIKey = roboflowAPIKey
            self.minimumConfidence = minimumConfidence
            self.onMeasurementUpdated = onMeasurementUpdated
            self.onDetectionsUpdated = onDetectionsUpdated
            self.onDebugFrameUpdated = onDebugFrameUpdated
            self.onDetectorStatusUpdated = onDetectorStatusUpdated
        }

        func update(apiKey: String, minimumConfidence: Double) {
            let normalizedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            self.minimumConfidence = minimumConfidence
            guard normalizedKey != roboflowAPIKey else { return }

            roboflowAPIKey = normalizedKey
            detector = nil
            screenDetections = []
            onDetectionsUpdated([])
            onDetectorStatusUpdated(normalizedKey.isEmpty ? "Missing Roboflow key" : "Roboflow ready")
        }

        func startMeasuring() {
            displayLink?.invalidate()
            let link = CADisplayLink(target: self, selector: #selector(updateMeasurement))
            link.preferredFramesPerSecond = 10
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopMeasuring() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc
        private func updateMeasurement() {
            guard let arView,
                  arView.bounds.width > 0,
                  arView.bounds.height > 0 else {
                return
            }

            tick += 1
            guard tick % 3 == 0 else { return }

            if tick % 15 == 0 {
                detectLumberIfNeeded(in: arView)
            }

            guard let pair = selectedMeasurementPair() else {
                onMeasurementUpdated(0, 0)
                return
            }

            guard let left = worldPoint(at: pair.left, in: arView),
                  let right = worldPoint(at: pair.right, in: arView) else {
                onMeasurementUpdated(0, 0)
                return
            }

            let distanceMeters = simd_distance(left, right)
            let distanceInches = Double(distanceMeters) * 39.3701
            let clampedDistance = min(max(distanceInches, 0), 96)
            onMeasurementUpdated(clampedDistance, pair.confidence)
        }

        private func worldPoint(at screenPoint: CGPoint, in arView: ARView) -> SIMD3<Float>? {
            let verticalQuery = arView.raycast(
                from: screenPoint,
                allowing: .estimatedPlane,
                alignment: .vertical
            ).first

            let fallbackQuery = arView.raycast(
                from: screenPoint,
                allowing: .estimatedPlane,
                alignment: .any
            ).first

            guard let result = verticalQuery ?? fallbackQuery else {
                return nil
            }

            let translation = result.worldTransform.columns.3
            return SIMD3<Float>(translation.x, translation.y, translation.z)
        }

        private func selectedMeasurementPair() -> (left: CGPoint, right: CGPoint, confidence: Double)? {
            let sortedDetections = screenDetections
                .filter { $0.confidence >= minimumConfidence }
                .sorted { lhs, rhs in
                    lhs.frame.midX < rhs.frame.midX
                }

            guard let first = sortedDetections.first,
                  let last = sortedDetections.last,
                  first.id != last.id else {
                return nil
            }

            return (first.center, last.center, min(first.confidence, last.confidence))
        }

        private func detectLumberIfNeeded(in arView: ARView) {
            let apiKey = roboflowAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                print("Roboflow disabled: ROBOFLOW_API_KEY is empty. Create app-ios/Config/Secrets.xcconfig.")
                onDetectorStatusUpdated("Missing Roboflow key")
                return
            }

            guard !isDetecting, let frame = arView.session.currentFrame else { return }
            isDetecting = true
            onDetectorStatusUpdated("Roboflow scanning")

            let viewSize = arView.bounds.size
            let pixelBuffer = frame.capturedImage

            Task { [weak self] in
                guard let self else { return }

                do {
                    if detector == nil {
                        onDetectorStatusUpdated("Loading model")
                        let detector = RoboflowLumberDetector(apiKey: apiKey)
                        try await detector.prepareModel()
                        onDetectorStatusUpdated(detector.runtimeStatus)
                        self.detector = detector
                    }

                    guard let image = image(from: pixelBuffer) else {
                        screenDetections = []
                        onDetectionsUpdated([])
                        onDetectorStatusUpdated("No frame")
                        isDetecting = false
                        return
                    }

                    let result = try await detector?.detectLumber(
                        in: image,
                        minimumConfidence: minimumConfidence
                    ) ?? RoboflowDetectionResult(acceptedLumber: [], debugDetections: [])
                    onDebugFrameUpdated(RoboflowDebugFrame(image: image, detections: result.debugDetections))
                    screenDetections = result.acceptedLumber.map { detection in
                        LumberDetection(
                            frame: self.scale(detection.frame, from: image.size, to: viewSize),
                            confidence: detection.confidence,
                            className: detection.className
                        )
                    }
                    onDetectionsUpdated(screenDetections)
                    let status = screenDetections.count >= 2 ? "\(screenDetections.count) lumber" : "Need 2 lumber"
                    onDetectorStatusUpdated(screenDetections.isEmpty ? "No lumber" : status)
                } catch {
                    screenDetections = []
                    onDetectionsUpdated([])
                    onDetectorStatusUpdated("Roboflow error")
                }

                isDetecting = false
            }
        }

        private func image(from pixelBuffer: CVPixelBuffer) -> UIImage? {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            guard let cgImage = imageContext.createCGImage(ciImage, from: ciImage.extent) else {
                return nil
            }

            return UIImage(cgImage: cgImage)
        }

        private func scale(_ frame: CGRect, from imageSize: CGSize, to viewSize: CGSize) -> CGRect {
            guard imageSize.width > 0, imageSize.height > 0 else {
                return .zero
            }

            let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
            let scaledImageSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let offset = CGPoint(
                x: (viewSize.width - scaledImageSize.width) / 2,
                y: (viewSize.height - scaledImageSize.height) / 2
            )

            return CGRect(
                x: frame.minX * scale + offset.x,
                y: frame.minY * scale + offset.y,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }
    }
}
