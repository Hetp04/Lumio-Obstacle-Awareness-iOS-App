import Foundation
import Combine
import Porcupine
import Cheetah
import Orca
import AVFoundation

class VoiceViewModel: ObservableObject {

    enum AppState {
        case waiting
        case listening
        case processing
    }
    @Published var appState: AppState = .waiting
    @Published var partialTranscript: String = ""
    @Published var ocrTextForUI: String = ""

    private var porcupine: Porcupine?
    private var cheetah: Cheetah?
    private var orca: Orca?
    private let accessKey = "Xyt7RTtQXqncJ99+NxuIhGSpLXUaxY9yZRGlYgCaway9zXJso6LcPw=="

    private weak var audioManager: SpatialAudioManager?
    private var ocrManager: OCRWebSocketManager
    private var cancellables = Set<AnyCancellable>()

    var latestPixelBuffer: CVPixelBuffer?

    init(ocrManager: OCRWebSocketManager) {
        self.ocrManager = ocrManager

        do {
            try setupPicovoice()
            subscribeToOCRManager()
        } catch {
            print("❌ PICOVOICE ERROR: \(error.localizedDescription)")
            self.ocrTextForUI = "Picovoice init failed."
        }
    }

    func setAudioManager(_ audioManager: SpatialAudioManager) {
        self.audioManager = audioManager
    }

    public func processAudio(pcm: [Int16]) {
        guard appState == .waiting || appState == .listening else { return }

        do {
            if appState == .waiting {
                let result = try porcupine?.process(pcm: pcm)
                if result == 0 {
                    handleWakeWord()
                }
            } else if appState == .listening {
                guard let cheetah = self.cheetah else { return }

                let (partial, isEndpoint) = try cheetah.process(pcm)

                if !partial.isEmpty {
                    DispatchQueue.main.async {
                        self.partialTranscript += partial
                    }
                }

                if isEndpoint {
                    let finalTranscript = try cheetah.flush()
                    handleCommand(partialTranscript + finalTranscript)
                }
            }
        } catch {
            print("❌ PICOVOICE process error: \(error)")
            DispatchQueue.main.async { self.appState = .waiting }
        }
    }

    private func handleWakeWord() {
        print("✅ Wake word detected!")
        DispatchQueue.main.async {
            self.appState = .listening
            self.partialTranscript = ""
            self.ocrTextForUI = "Yes?..."
        }
    }

    private func handleCommand(_ transcript: String) {
        let command = transcript.lowercased().trimmingCharacters(in: .whitespaces)
        print("Command received: '\(command)'")

        if command.contains("read this for me") {
            print("✅ Command recognized! Triggering OCR.")
            DispatchQueue.main.async {
                self.appState = .processing
                self.ocrTextForUI = "Reading..."
            }

        } else {
            print("❓ Unknown command. Returning to wait.")
            DispatchQueue.main.async {
                self.ocrTextForUI = "Unknown command."
            }
            returnToWaiting()
        }
    }

    private func subscribeToOCRManager() {
        ocrManager.$ocrText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newText in
                self?.handleOCRText(newText)
            }
            .store(in: &cancellables)
    }

    private func handleOCRText(_ text: String) {
        guard appState == .processing, !text.isEmpty else { return }

        guard let orca = self.orca, let sampleRate = orca.sampleRate else {
            print("❌ Orca engine or its sample rate is not available.")
            returnToWaiting()
            return
        }

        print("Synthesizing: \(text)")
        self.ocrTextForUI = text

        do {
            let (pcm, _) = try orca.synthesize(text: text)
        } catch {
            print("❌ Orca synthesis error: \(error)")
            returnToWaiting()
        }
    }

    func ttsDidFinish() {
        print("TTS finished. Returning to wait.")
        returnToWaiting()
    }

    func linkAudioAndPreload(audioManager: SpatialAudioManager) {
        self.setAudioManager(audioManager)

        guard let orca = self.orca, let sampleRate = orca.sampleRate else {
            print("❌ Orca not ready or sample rate is nil")
            return
        }

        do {
            let (pcm, _) = try orca.synthesize(text: "Yes?")
        } catch {
            print("❌ Orca failed to synthesize 'Yes?': \(error)")
        }
    }

    private func returnToWaiting() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.appState = .waiting
            self.partialTranscript = ""
            self.ocrTextForUI = ""
        }
    }

    private func setupPicovoice() throws {
        guard let porcupinePath = Bundle.main.path(forResource: "Hey-Lumio_en_ios_v3_0_0", ofType: "ppn") else {
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "Missing Hey-Lumio .ppn file"])
        }
        guard let cheetahModelPath = Bundle.main.path(forResource: "Lumio-cheetah-default-v2.3.0-25-10-26--08-24-03", ofType: "pv") else {
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "Missing Cheetah .pv file"])
        }
        guard let orcaModelPath = Bundle.main.path(forResource: "orca_params_en_male", ofType: "pv") else {
            throw URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "Missing Orca .pv file"])
        }

        self.porcupine = try Porcupine(
            accessKey: accessKey,
            keywordPaths: [porcupinePath],
            modelPath: nil,
            sensitivities: [0.5]
        )
        print("✅ Porcupine (Engine) initialized.")
        print("✅ Porcupine (Wake Word) initialized.")

        self.cheetah = try Cheetah(
            accessKey: accessKey,
            modelPath: cheetahModelPath,
            endpointDuration: 1.0,
            enableAutomaticPunctuation: true
        )
        print("✅ Cheetah (STT) initialized.")

        self.orca = try Orca(accessKey: accessKey, modelPath: orcaModelPath)
        print("✅ Orca (TTS) initialized.")
    }
}
