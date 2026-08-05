import SceneKit
import SwiftUI

struct TP7DeviceSceneView: NSViewRepresentable {
    let selectedRole: TP7InputRole

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .clear
        view.rendersContinuously = true
        view.scene = context.coordinator.makeScene()
        view.pointOfView = context.coordinator.pointOfView
        context.coordinator.focus(on: selectedRole, animated: false)
        context.coordinator.playIntroIfNeeded()
        DispatchQueue.main.async {
            view.pointOfView = context.coordinator.pointOfView
        }
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        nsView.pointOfView = context.coordinator.pointOfView
        context.coordinator.focus(on: selectedRole, animated: true)
        DispatchQueue.main.async {
            nsView.pointOfView = context.coordinator.pointOfView
        }
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let deviceRoot = SCNNode()
        private let cameraNode = SCNNode()
        private let cameraTarget = SCNNode()
        private var didPlayIntro = false
        private var focusedRole: TP7InputRole?

        var pointOfView: SCNNode {
            cameraNode
        }

        func makeScene() -> SCNScene {
            scene.rootNode.childNodes.forEach { $0.removeFromParentNode() }
            deviceRoot.childNodes.forEach { $0.removeFromParentNode() }
            deviceRoot.name = "TP7DeviceRoot"
            scene.rootNode.addChildNode(deviceRoot)
            scene.rootNode.addChildNode(cameraTarget)

            if let imported = Self.loadImportedScene() {
                addImportedScene(imported)
            } else {
                addMissingAssetMarker()
            }

            addCameraAndLights()
            return scene
        }

        func playIntroIfNeeded() {
            guard !didPlayIntro else { return }
            didPlayIntro = true
            deviceRoot.eulerAngles.y = -0.18
            deviceRoot.eulerAngles.z = 0.025

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 1.45
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            deviceRoot.eulerAngles.y = 0
            deviceRoot.eulerAngles.z = 0
            SCNTransaction.commit()
        }

        func focus(on role: TP7InputRole, animated: Bool) {
            guard focusedRole != role || !animated else { return }
            focusedRole = role
            let focus = Self.focusPreset(for: role)

            let updates = {
                self.cameraTarget.position = focus.target
                self.cameraNode.position = focus.camera
                self.cameraNode.camera?.fieldOfView = focus.fieldOfView
                self.cameraNode.camera?.orthographicScale = focus.orthographicScale
            }

            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.72
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                updates()
                SCNTransaction.commit()
            } else {
                updates()
            }
        }

        private func addImportedScene(_ imported: SCNScene) {
            imported.rootNode.childNodes.forEach { child in
                child.removeFromParentNode()
                deviceRoot.addChildNode(child)
            }
            Self.prepareImportedMaterials(in: deviceRoot)

            let bounds = deviceRoot.boundingBox
            let center = SCNVector3(
                (bounds.min.x + bounds.max.x) / 2,
                (bounds.min.y + bounds.max.y) / 2,
                (bounds.min.z + bounds.max.z) / 2
            )
            let width = max(bounds.max.x - bounds.min.x, 0.01)
            let depth = max(bounds.max.z - bounds.min.z, 0.01)
            let scale = 7.4 / max(width, depth)

            deviceRoot.scale = SCNVector3(scale, scale, scale)
            deviceRoot.position = SCNVector3(-center.x * scale, -center.y * scale, -center.z * scale)
        }

        private static func prepareImportedMaterials(in root: SCNNode) {
            root.enumerateChildNodes { node, _ in
                guard let geometry = node.geometry else { return }
                for material in geometry.materials {
                    material.isDoubleSided = true
                    let materialName = material.name?.lowercased() ?? ""
                    if materialName.contains("decals"),
                       Self.shouldHideUnstableDetailDecal(nodeName: node.name) {
                        node.isHidden = true
                        continue
                    }
                    if materialName.contains("blasted_aluminum") {
                        material.diffuse.contents = NSColor(calibratedWhite: 0.52, alpha: 1)
                        material.diffuse.intensity = 0.88
                        material.roughness.contents = 0.84
                        material.metalness.contents = 0.36
                        material.specular.intensity = 0.10
                    } else if materialName.contains("material_005") || materialName.contains("material_001") {
                        material.diffuse.intensity = 0.84
                        material.roughness.contents = 0.82
                        material.specular.intensity = 0.11
                    }
                    guard materialName.contains("decals") else { continue }

                    node.renderingOrder = materialName.contains("lum") ? 1200 : 1100
                    material.blendMode = .alpha
                    material.lightingModel = .constant
                    material.writesToDepthBuffer = false
                    material.readsFromDepthBuffer = false
                    material.transparencyMode = .aOne
                    material.diffuse.intensity = 1.18
                    material.emission.intensity = materialName.contains("lum") ? 2.2 : 0.2
                }
            }
        }

        private static func shouldHideUnstableDetailDecal(nodeName: String?) -> Bool {
            guard let nodeName else { return false }
            return nodeName == "Object_29"
                || nodeName == "Object_32"
                || nodeName == "Object_35"
                || nodeName == "Object_36"
        }

        private func addCameraAndLights() {
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 35
            cameraNode.camera?.usesOrthographicProjection = true
            cameraNode.camera?.orthographicScale = 5.2
            cameraNode.camera?.wantsHDR = true
            cameraNode.camera?.wantsExposureAdaptation = true
            cameraNode.camera?.exposureOffset = -0.48

            let lookAt = SCNLookAtConstraint(target: cameraTarget)
            lookAt.isGimbalLockEnabled = true
            cameraNode.constraints = [lookAt]
            scene.rootNode.addChildNode(cameraNode)

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .area
            key.light?.intensity = 180
            key.light?.areaType = .rectangle
            key.light?.areaExtents = simd_float3(15, 12, 1)
            key.position = SCNVector3(-5.2, 9.2, 8.4)
            scene.rootNode.addChildNode(key)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 72
            ambient.light?.color = NSColor(calibratedWhite: 0.62, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.intensity = 92
            fill.position = SCNVector3(4.8, 5.2, -5.6)
            scene.rootNode.addChildNode(fill)

            let lowerLeftFill = SCNNode()
            lowerLeftFill.light = SCNLight()
            lowerLeftFill.light?.type = .area
            lowerLeftFill.light?.intensity = 88
            lowerLeftFill.light?.areaType = .rectangle
            lowerLeftFill.light?.areaExtents = simd_float3(7, 5, 1)
            lowerLeftFill.position = SCNVector3(-5.8, 3.0, 5.2)
            scene.rootNode.addChildNode(lowerLeftFill)

            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light?.type = .omni
            rim.light?.intensity = 28
            rim.position = SCNVector3(0, 2.2, -7.0)
            scene.rootNode.addChildNode(rim)
        }

        private static func loadImportedScene() -> SCNScene? {
            guard let url = resourceURL(named: "tp7", extension: "usdz") else { return nil }
            return try? SCNScene(url: url)
        }

        private static func resourceURL(named name: String, extension fileExtension: String) -> URL? {
            if let url = Bundle.module.url(forResource: name, withExtension: fileExtension) {
                return url
            }
            if let url = Bundle.module.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: "TP7Model.scnassets"
            ) {
                return url
            }
            if let resourceURL = Bundle.main.resourceURL {
                let bundleURL = resourceURL
                    .appendingPathComponent("TP7VibeInput_TP7VibeInput.bundle")
                    .appendingPathComponent("\(name).\(fileExtension)")
                if FileManager.default.fileExists(atPath: bundleURL.path) {
                    return bundleURL
                }
            }
            return nil
        }

        private static func focusPreset(for role: TP7InputRole) -> (
            target: SCNVector3,
            camera: SCNVector3,
            fieldOfView: CGFloat,
            orthographicScale: CGFloat
        ) {
            let target = targetPoint(for: role)
            let lens = lensPreset(for: role)
            let sideBias = target.x * lens.sideBias
            return (
                target,
                SCNVector3(target.x + sideBias + lens.extraX, lens.height, target.z + lens.pullBack),
                lens.fieldOfView,
                lens.orthographicScale
            )
        }

        private static func lensPreset(for role: TP7InputRole) -> (
            height: CGFloat,
            pullBack: CGFloat,
            sideBias: CGFloat,
            extraX: CGFloat,
            fieldOfView: CGFloat,
            orthographicScale: CGFloat
        ) {
            switch role {
            case .wheel:
                (11.4, 7.6, 0.16, 0.0, 42, 5.15)
            case .rec:
                (5.0, 2.45, 0.08, 0.05, 29, 2.62)
            case .play:
                (5.0, 2.35, 0.0, 0.0, 29, 2.48)
            case .stop:
                (5.0, 2.45, 0.06, -0.06, 29, 2.62)
            case .plus:
                (5.35, 3.35, 0.10, -0.52, 29, 3.28)
            case .minus:
                (4.85, 2.82, 0.08, 0.06, 29, 3.05)
            case .sideForward, .sideBackward:
                (5.25, 3.35, 0.10, -0.34, 29, 3.92)
            case .memo:
                (5.1, 3.25, 0.16, 0.08, 29, 3.72)
            case .menu:
                (4.85, 2.85, 0.22, 0.16, 29, 3.18)
            case .learned1, .learned2, .learned3, .learned4:
                (5.6, 3.7, 0.16, 0.0, 29, 4.15)
            }
        }

        private static func targetPoint(for role: TP7InputRole) -> SCNVector3 {
            switch role {
            case .rec:
                SCNVector3(-1.58, 0.42, 3.05)
            case .play:
                SCNVector3(-0.30, 0.42, 3.05)
            case .stop:
                SCNVector3(0.86, 0.42, 3.05)
            case .plus:
                SCNVector3(1.52, 0.52, 1.12)
            case .minus:
                SCNVector3(1.92, 0.52, 0.48)
            case .sideForward:
                SCNVector3(-2.16, 0.36, -0.85)
            case .sideBackward:
                SCNVector3(-2.16, 0.36, 0.82)
            case .memo:
                SCNVector3(1.80, 0.52, -2.85)
            case .menu:
                SCNVector3(-1.82, 0.48, 1.92)
            case .wheel:
                SCNVector3(0.0, 0.30, -0.25)
            case .learned1:
                SCNVector3(-1.3, 0.42, -0.95)
            case .learned2:
                SCNVector3(1.3, 0.42, -0.95)
            case .learned3:
                SCNVector3(-1.3, 0.42, 1.15)
            case .learned4:
                SCNVector3(1.3, 0.42, 1.15)
            }
        }

        private func addMissingAssetMarker() {
            let panel = SCNNode(geometry: SCNBox(width: 5.8, height: 0.18, length: 2.4, chamferRadius: 0.18))
            panel.geometry?.materials = [Self.material(color: NSColor.systemRed.withAlphaComponent(0.88), metalness: 0.1, roughness: 0.42)]
            deviceRoot.addChildNode(panel)

            let text = SCNText(string: "TP-7 USDZ missing", extrusionDepth: 0.02)
            text.font = .systemFont(ofSize: 0.34, weight: .semibold)
            text.alignmentMode = CATextLayerAlignmentMode.center.rawValue
            text.firstMaterial = Self.material(color: .white, metalness: 0, roughness: 0.2)

            let textNode = SCNNode(geometry: text)
            textNode.position = SCNVector3(-2.45, 0.18, -0.18)
            textNode.eulerAngles.x = -.pi / 2
            deviceRoot.addChildNode(textNode)
        }

        private static func material(color: NSColor, metalness: CGFloat, roughness: CGFloat) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.metalness.contents = metalness
            material.roughness.contents = roughness
            return material
        }
    }
}
