import AVFoundation
import UIKit
import Combine

class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    @Published var session = AVCaptureSession()
    @Published var error: Error?

    weak var webSocketManager: WebSocketManager?

    private let sessionQueue = DispatchQueue(label: "com.example.sessionQueue")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var frameRateTimer: Timer?

    private let targetFPS: Double = 20.0
    private let jpegQuality: CGFloat = 0.7

    override init() {
        super.init()
        setupSession()
    }

    func setupSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .vga640x480

            guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice) else {
                print("Failed to get camera device")
                return
            }

            if self.session.canAddInput(videoDeviceInput) {
                self.session.addInput(videoDeviceInput)
            }

            self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            self.videoOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true

            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            self.session.commitConfiguration()
        }
    }

    func start() {
        print("Starting camera session...")
        sessionQueue.async {
            self.session.startRunning()

            DispatchQueue.main.async {
                self.frameRateTimer?.invalidate()
                self.frameRateTimer = Timer.scheduledTimer(
                    withTimeInterval: 1.0 / self.targetFPS,
                    repeats: true
                ) { [weak self] _ in
                }
            }
        }
    }

    func stop() {
        print("Stopping camera session...")
        sessionQueue.async {
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.frameRateTimer?.invalidate()
                self.frameRateTimer = nil
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frameData = self.jpegData(from: imageBuffer) else {
            return
        }

        webSocketManager?.sendFrame(frameData)
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }

        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: self.jpegQuality)
    }
}
