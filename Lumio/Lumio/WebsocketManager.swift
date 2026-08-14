import Foundation
import Combine

class WebSocketManager: ObservableObject {
    private var webSocketTask: URLSessionWebSocketTask?
    private var session = URLSession(configuration: .default)

    private let serverURL = URL(string: "wss://serve-gorgeous-civil-testimony.trycloudflare.com/ws")!
    private var frameId: Int = 0

    private var isAwaitingResponse: Bool = false

    @Published var tracks: [Track] = []
    @Published var latency: Double = 0.0
    @Published var isConnected: Bool = false

    init() {
        connect()
    }

    func connect() {
        guard !isConnected else { return }
        webSocketTask = session.webSocketTask(with: serverURL)
        webSocketTask?.resume()
        isConnected = true
        isAwaitingResponse = false
        print("Connecting to WebSocket...")
        listen()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        isConnected = false
        tracks = []
        print("Disconnected from WebSocket.")
    }

    private func listen() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .failure(let error):
                print("WebSocket receive error: \(error.localizedDescription)")
                self.isConnected = false
                self.isAwaitingResponse = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.connect()
                }

            case .success(let message):
                switch message {
                case .string(let text):
                    self.parseResponse(jsonString: text)
                    print("received response from frame")
                case .data(let data):
                    print("Received unexpected binary data: \(data.count) bytes")
                @unknown default:
                    fatalError()
                }
                self.listen()
            }
        }
    }

    private func parseResponse(jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else { return }

        do {
            let response = try JSONDecoder().decode(ServerResponse.self, from: data)

            DispatchQueue.main.async {
                self.tracks = response.tracks
                self.latency = response.latencyMs ?? 0.0

                print("received processed frame", self.frameId)
                self.isAwaitingResponse = false
            }
        } catch {
            print("JSON Decoding Error: \(error.localizedDescription)")
        }
    }

    func sendFrame(_ frameData: Data) {
        guard isConnected, let task = webSocketTask else {
            print("Cannot send frame, not connected.")
            return
        }

        guard !isAwaitingResponse else {
            return
        }

        isAwaitingResponse = true
        print("sending frame", frameId)
        var id = UInt64(frameId).littleEndian
        let header = Data(bytes: &id, count: MemoryLayout<UInt64>.size)

        var payload = Data()
        payload.append(header)
        payload.append(frameData)

        task.send(.data(payload)) { [weak self] error in
            if let error = error {
                print("Error sending binary payload: \(error.localizedDescription)")
                self?.isAwaitingResponse = false
            }
        }

        frameId += 1
    }
}
