import AVFoundation
import Combine

class NativeTTSManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private var timer: Timer?

    private var currentTracks: [Track] = []

    @Published var isSpeaking = false

    override init() {
        super.init()
        self.synthesizer.delegate = self

        self.timer = Timer.scheduledTimer(
            withTimeInterval: 0.75,
            repeats: true
        ) { [weak self] _ in
            self?.processStoredTracks()
        }
    }

    func updateCurrentTracks(_ tracks: [Track]) {
        self.currentTracks = tracks
    }

    private func processStoredTracks() {
        guard !isSpeaking else {
            print("Native TTS: Timer fired, but already speaking. Waiting for next cycle.")
            return
        }

        let highPriorityTracks = currentTracks.filter { $0.priority == "high" }

        guard let trackToAnnounce = highPriorityTracks.randomElement() else {
            return
        }

        guard let label = trackToAnnounce.label, let direction = trackToAnnounce.direction else {
            return
        }
        let textToSpeak = generateString(label: label, direction: direction)

        print("Native TTS: Timer fired. Preparing to announce '\"\(textToSpeak)\"'")
        self.speak(textToSpeak)
    }

    private func generateString(label: String, direction: String) -> String {
        if (label == "person") {
            if (direction == "straight") {
                return "Person straight ahead of you."
            }
            return "Person moving to the \(direction), from your \(direction == "left" ? "right" : "left")."
        } else {
            if (direction == "straight") {
                return "Caution! \(label) in front of you."
            }
            return "Caution! \(label) on your \(direction)."
        }
    }

    private func speak(_ text: String) {
        guard !isSpeaking else { return }

        isSpeaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        synthesizer.speak(utterance)
    }

    deinit {
        timer?.invalidate()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            print("Native TTS: Finished speaking.")
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        DispatchQueue.main.async {
            self.isSpeaking = false
            print("Native TTS: Speech cancelled.")
        }
    }

}
