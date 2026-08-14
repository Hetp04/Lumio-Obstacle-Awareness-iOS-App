import SwiftUI
import ARKit
import SceneKit
import AVFoundation
import CoreImage
import Combine

struct ContentView: View {
    @State private var distances: [String: Float] = ["Left": 99, "Center": 99, "Right": 99]
    @State private var lastTriggerTime = Date(timeIntervalSince1970: 0)

    @State private var tracks: [Track] = []
    @State private var arImageResolution: CGSize = .zero

    @StateObject private var webSocketManager = WebSocketManager()
    @StateObject private var ocrWebSocketManager = OCRWebSocketManager()

    private let audioManager: SpatialAudioManager
    @StateObject private var ttsManager = NativeTTSManager()

    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .heavy)

    init() {
        let am = SpatialAudioManager()
        self.audioManager = am

    }

    var body: some View {
        ZStack {
            ARViewContainer(distances: $distances,
                            lastTriggerTime: $lastTriggerTime,
                            tracks: $tracks,
                            audioManager: audioManager,
                            webSocketManager: webSocketManager,
                            imageResolution: $arImageResolution)
            .edgesIgnoringSafeArea(.all)

            DetectionOverlayView(tracks: tracks,
                                 imageResolution: arImageResolution)

            VStack {
                Spacer()
                HStack(spacing: 20) {
                    ForEach(["Left", "Center", "Right"], id: \.self) { zone in
                        if let distance = distances[zone] {
                            VStack {
                                Text("Zone \(zone)")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                Text(String(format: "%.2f m", distance))
                                    .foregroundColor(distance < 0.5 ? .red : .white)
                            }
                            .padding()
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(12)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onReceive(webSocketManager.$tracks) { newTracks in
            self.tracks = newTracks

            ttsManager.updateCurrentTracks(newTracks)
        }
        .onAppear {
            feedbackGenerator.prepare()
        }
        .onDisappear {
            webSocketManager.disconnect()
        }
    }
}
