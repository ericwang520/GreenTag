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
        private struct MeasurementPair {
            let left: CGPoint
            let right: CGPoint
            let confidence: Double
        }

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
        private var candidatePair: MeasurementPair?
        private var candidatePairConfirmationCount = 0
        private var confirmedPair: MeasurementPair?
        private var lockedMeasurement: (spacingIn: Double, confidence: Double)?
        private var lastDetectionTime: CFTimeInterval = 0
        private var lastDetectionTransform: simd_float4x4?
        private let requiredPairConfirmations = 1
        private let pairStabilityTolerance: CGFloat = 60
        private let minimumDetectionInterval: CFTimeInterval = 1.2
        private let cameraTranslationThreshold: Float = 0.08
        private let cameraRotationThreshold: Float = 0.09

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
            resetPairConfirmation()
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

            guard let pair = confirmedPair else {
                onMeasurementUpdated(0, 0)
                return
            }

            if let lockedMeasurement {
                onMeasurementUpdated(lockedMeasurement.spacingIn, lockedMeasurement.confidence)
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
            lockedMeasurement = (clampedDistance, pair.confidence)
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

        private func selectedMeasurementPair(from detections: [LumberDetection]) -> MeasurementPair? {
            let sortedDetections = detections
                .filter { $0.confidence >= minimumConfidence }
                .sorted { lhs, rhs in
                    lhs.frame.midX < rhs.frame.midX
                }

            guard sortedDetections.count >= 2 else {
                return nil
            }

            let closestPair = zip(sortedDetections, sortedDetections.dropFirst())
                .min { lhs, rhs in
                    abs(lhs.1.center.x - lhs.0.center.x) < abs(rhs.1.center.x - rhs.0.center.x)
                }

            guard let closestPair else {
                return nil
            }

            return MeasurementPair(
                left: closestPair.0.center,
                right: closestPair.1.center,
                confidence: min(closestPair.0.confidence, closestPair.1.confidence)
            )
        }

        private func detectLumberIfNeeded(in arView: ARView) {
            let apiKey = roboflowAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else {
                print("Roboflow disabled: ROBOFLOW_API_KEY is empty. Create app-ios/Config/Secrets.xcconfig.")
                onDetectorStatusUpdated("Missing Roboflow key")
                return
            }

            guard !isDetecting, let frame = arView.session.currentFrame else { return }
            guard shouldRunDetection(for: frame) else { return }

            let transform = frame.camera.transform
            if let lastDetectionTransform,
               cameraMovedEnough(from: lastDetectionTransform, to: transform) {
                resetPairConfirmation()
                onMeasurementUpdated(0, 0)
            }

            isDetecting = true
            lastDetectionTime = CACurrentMediaTime()
            lastDetectionTransform = transform
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
                        resetPairConfirmation()
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
                    let viewBounds = CGRect(origin: .zero, size: viewSize)
                    screenDetections = result.acceptedLumber.compactMap { detection in
                        let scaledFrame = self.scale(detection.frame, from: image.size, to: viewSize)
                        let visibleFrame = scaledFrame.intersection(viewBounds)
                        guard visibleFrame.width >= 8, visibleFrame.height >= 8 else {
                            print(
                                String(
                                    format: "Roboflow detection hidden offscreen class=%@ confidence=%.3f scaled_box=(x: %.1f, y: %.1f, w: %.1f, h: %.1f)",
                                    detection.className,
                                    detection.confidence,
                                    scaledFrame.origin.x,
                                    scaledFrame.origin.y,
                                    scaledFrame.size.width,
                                    scaledFrame.size.height
                                )
                            )
                            return nil
                        }

                        return LumberDetection(
                            frame: visibleFrame,
                            confidence: detection.confidence,
                            className: detection.className
                        )
                    }
                    onDetectionsUpdated(screenDetections)
                    updatePairConfirmation()
                    let status = detectorStatusForCurrentDetections()
                    onDetectorStatusUpdated(status)
                } catch {
                    screenDetections = []
                    resetPairConfirmation()
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

        private func shouldRunDetection(for frame: ARFrame) -> Bool {
            let now = CACurrentMediaTime()
            guard now - lastDetectionTime >= minimumDetectionInterval else {
                return false
            }

            guard let lastDetectionTransform else {
                return true
            }

            if confirmedPair == nil {
                return true
            }

            return cameraMovedEnough(from: lastDetectionTransform, to: frame.camera.transform)
        }

        private func cameraMovedEnough(from oldTransform: simd_float4x4, to newTransform: simd_float4x4) -> Bool {
            let oldPosition = SIMD3<Float>(
                oldTransform.columns.3.x,
                oldTransform.columns.3.y,
                oldTransform.columns.3.z
            )
            let newPosition = SIMD3<Float>(
                newTransform.columns.3.x,
                newTransform.columns.3.y,
                newTransform.columns.3.z
            )

            let translation = simd_distance(oldPosition, newPosition)
            let oldForward = simd_normalize(SIMD3<Float>(
                oldTransform.columns.2.x,
                oldTransform.columns.2.y,
                oldTransform.columns.2.z
            ))
            let newForward = simd_normalize(SIMD3<Float>(
                newTransform.columns.2.x,
                newTransform.columns.2.y,
                newTransform.columns.2.z
            ))
            let dotValue = max(-1, min(1, simd_dot(oldForward, newForward)))
            let rotation = acos(dotValue)

            return translation >= cameraTranslationThreshold || rotation >= cameraRotationThreshold
        }

        private func updatePairConfirmation() {
            guard let pair = selectedMeasurementPair(from: screenDetections) else {
                resetPairConfirmation()
                onMeasurementUpdated(0, 0)
                return
            }

            if let candidatePair, isSimilar(pair, to: candidatePair) {
                candidatePairConfirmationCount += 1
            } else {
                candidatePair = pair
                candidatePairConfirmationCount = 1
                confirmedPair = nil
                lockedMeasurement = nil
                onMeasurementUpdated(0, 0)
            }

            if candidatePairConfirmationCount >= requiredPairConfirmations {
                if confirmedPair == nil {
                    lockedMeasurement = nil
                }
                confirmedPair = pair
            }
        }

        private func resetPairConfirmation() {
            candidatePair = nil
            candidatePairConfirmationCount = 0
            confirmedPair = nil
            lockedMeasurement = nil
        }

        private func isSimilar(_ lhs: MeasurementPair, to rhs: MeasurementPair) -> Bool {
            abs(lhs.left.x - rhs.left.x) <= pairStabilityTolerance &&
                abs(lhs.left.y - rhs.left.y) <= pairStabilityTolerance &&
                abs(lhs.right.x - rhs.right.x) <= pairStabilityTolerance &&
                abs(lhs.right.y - rhs.right.y) <= pairStabilityTolerance
        }

        private func detectorStatusForCurrentDetections() -> String {
            if screenDetections.isEmpty {
                return "No lumber"
            }

            if confirmedPair != nil {
                return "\(screenDetections.count) lumber"
            }

            if candidatePair != nil {
                return "Confirming studs \(candidatePairConfirmationCount)/\(requiredPairConfirmations)"
            }

            return screenDetections.count >= 2 ? "Confirming studs" : "Need 2 lumber"
        }
    }
}
