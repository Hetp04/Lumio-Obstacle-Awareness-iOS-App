import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import CoreImage
import Combine

struct ARViewContainer: UIViewRepresentable {
    @Binding var distances: [String: Float]
    @Binding var lastTriggerTime: Date
    @Binding var tracks: [Track]

    let audioManager: SpatialAudioManager
    let webSocketManager: WebSocketManager

    @Binding var imageResolution: CGSize

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.scene = SCNScene()
        arView.autoenablesDefaultLighting = true

        let config = ARWorldTrackingConfiguration()

        if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: {
            $0.imageResolution.width == 640 && $0.imageResolution.height == 480
        }) {
            config.videoFormat = format
            print("✅ ARSession video format set to 640x480.")
        } else {
            print("⚠️ Could not find 640x480 format. Using default. Bounding boxes may be misaligned.")
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }

        config.frameSemantics = .sceneDepth
        config.environmentTexturing = .automatic

        arView.session.run(config)

        context.coordinator.arView = arView

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self,
                    audioManager: audioManager,
                    webSocketManager: webSocketManager)
    }

    class Coordinator: NSObject, ARSCNViewDelegate {
        var parent: ARViewContainer
        let audioManager: SpatialAudioManager
        let webSocketManager: WebSocketManager

        private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)

        weak var arView: ARSCNView?
        var meshNodes: [UUID: SCNNode] = [:]
        var meshGeometryVersions: [UUID: Int] = [:]

        let maxDisplayDistance: Float = 6.0

        private let ciContext = CIContext()
        private let jpegQuality: CGFloat = 0.7
        private var hasSetResolution: Bool = false

        init(_ parent: ARViewContainer,
             audioManager: SpatialAudioManager,
             webSocketManager: WebSocketManager,
             ) {

            self.parent = parent
            self.audioManager = audioManager
            self.webSocketManager = webSocketManager
            super.init()
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard let arView = arView,
                  let frame = arView.session.currentFrame,
                  let pointOfView = arView.pointOfView
            else { return }

            if !hasSetResolution, let format = arView.session.configuration?.videoFormat {
                DispatchQueue.main.async {
                    self.parent.imageResolution = format.imageResolution
                    self.hasSetResolution = true
                    print("✅ Resolution source of truth set: \(format.imageResolution)")
                }
            }

            let pixelBuffer = frame.capturedImage

            if let frameData = self.jpegData(from: pixelBuffer) {
                self.webSocketManager.sendFrame(frameData)

            }

            if let sceneDepth = frame.sceneDepth {
                let depthMap = sceneDepth.depthMap
                let width = CVPixelBufferGetWidth(depthMap)
                let height = CVPixelBufferGetHeight(depthMap)

                CVPixelBufferLockBaseAddress(depthMap, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

                guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
                let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)

                var leftMin: Float = .greatestFiniteMagnitude
                var centerMin: Float = .greatestFiniteMagnitude
                var rightMin: Float = .greatestFiniteMagnitude

                let step = 8

                for y in stride(from: 0, to: height, by: step) {
                    for x in stride(from: 0, to: width, by: step) {
                        let index = y * width + x
                        let distance = floatBuffer[index]
                        if distance.isNaN || distance <= 0 { continue }

                        let px = Float(x - width / 2) / 500.0

                        if px < -0.1 { leftMin = min(leftMin, distance) }
                        else if px <= 0.1 { centerMin = min(centerMin, distance) }
                        else { rightMin = min(rightMin, distance) }
                    }
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }

                    self.parent.distances["Left"] = leftMin.isFinite ? leftMin : 99
                    self.parent.distances["Center"] = centerMin.isFinite ? centerMin : 99
                    self.parent.distances["Right"] = rightMin.isFinite ? rightMin : 99

                    if [leftMin, centerMin, rightMin].contains(where: { $0 < 0.5 }) {
                        let now = Date()
                        if now.timeIntervalSince(self.parent.lastTriggerTime) > 0.5 {
                            self.parent.lastTriggerTime = now
                            self.feedbackGenerator.impactOccurred()

                            if leftMin < 0.5 { self.audioManager.play(zone: "left") }
                            if centerMin < 0.5 { self.audioManager.play(zone: "center") }
                            if rightMin < 0.5 { self.audioManager.play(zone: "right") }
                        }
                    }
                }
            }

            let cameraTransform = frame.camera.transform
            let cameraPosition = simd_float3(cameraTransform.columns.3.x,
                                             cameraTransform.columns.3.y,
                                             cameraTransform.columns.3.z)

            let currentMeshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

            for anchor in currentMeshAnchors {
                let id = anchor.identifier
                let node: SCNNode
                let currentGeometryVersion = Int(anchor.geometry.vertices.buffer.length)

                if let existingNode = meshNodes[id] {
                    node = existingNode
                } else {
                    node = SCNNode()
                    meshNodes[id] = node
                    arView.scene.rootNode.addChildNode(node)
                    meshGeometryVersions[id] = -1
                }

                node.simdTransform = anchor.transform

                let anchorPosition = simd_float3(anchor.transform.columns.3.x,
                                                anchor.transform.columns.3.y,
                                                anchor.transform.columns.3.z)
                let distanceToAnchor = simd_distance(cameraPosition, anchorPosition)

                let isActive = distanceToAnchor <= maxDisplayDistance

                let isVisible = isActive && arView.isNode(node, insideFrustumOf: pointOfView)

                let geometryHasUpdated = meshGeometryVersions[id] != currentGeometryVersion

                node.isHidden = !isActive

                if isActive && (isVisible || geometryHasUpdated) {
                    node.geometry = anchor.geometry.toSCNGeometry(
                        cameraPosition: cameraPosition,
                        anchorTransform: anchor.transform
                    )
                    meshGeometryVersions[id] = currentGeometryVersion
                }
            }

            let currentIDs = Set(currentMeshAnchors.map { $0.identifier })
            let removedIDs = meshNodes.keys.filter { !currentIDs.contains($0) }

            for id in removedIDs {
                meshNodes[id]?.removeFromParentNode()
                meshNodes.removeValue(forKey: id)
                meshGeometryVersions.removeValue(forKey: id)
            }

        }

        private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            let properties: [CIImageRepresentationOption: Any] = [
                kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality
            ]

            return ciContext.jpegRepresentation(
                of: ciImage,
                colorSpace: ciImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                options: properties
            )
        }
    }
}

extension ARMeshGeometry {
    func toSCNGeometry(cameraPosition: simd_float3, anchorTransform: simd_float4x4) -> SCNGeometry {
        let vertexBuffer = vertices.buffer.contents()
        let vertexStride = vertices.stride
        let vertexOffset = vertices.offset
        let vertexCount = vertices.count

        var colors: [Float] = []
        colors.reserveCapacity(vertexCount * 3)

        for i in 0..<vertexCount {
            let vertexPointer = vertexBuffer.advanced(by: vertexOffset + (i * vertexStride))
            let vertex = vertexPointer.assumingMemoryBound(to: Float.self)

            let localVertex = simd_float3(vertex[0], vertex[1], vertex[2])

            let worldVertex = simd_make_float3(anchorTransform * simd_float4(localVertex, 1.0))

            let distance = simd_distance(cameraPosition, worldVertex)

            let r: Float
            let g: Float
            let b: Float

            if distance < 1.0 {
                r = 1.0
                g = distance
                b = 0.0
            } else if distance < 2.0 {
                let t2 = distance - 1.0
                r = 1.0 - t2
                g = 1.0
                b = 0.0
            } else {
                r = 0.0
                g = 1.0
                b = 0.0
            }

            colors.append(r)
            colors.append(g)
            colors.append(b)
        }

        let vertexSource = SCNGeometrySource(
            buffer: vertices.buffer,
            vertexFormat: .float3,
            semantic: .vertex,
            vertexCount: vertices.count,
            dataOffset: vertices.offset,
            dataStride: vertices.stride
        )

        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<Float>.size)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertexCount,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 3
        )

        let indexData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])

        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.white
        mat.isDoubleSided = true
        mat.fillMode = .lines
        mat.lightingModel = .constant

        geometry.materials = [mat]

        return geometry
    }
}
