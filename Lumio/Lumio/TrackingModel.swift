import Foundation

struct ServerResponse: Codable {
    let tracks: [Track]
    let latencyMs: Double?
    let zone: Zone?

    enum CodingKeys: String, CodingKey {
        case tracks
        case latencyMs = "latency_ms"
        case zone
    }
}

struct Track: Codable, Identifiable {
    let id: Int
    let bbox: [Double]
    let label: String?
    let conf: Double?
    let priority: String?
    let predPath: [[Double]]?

    let vx: Double?
    let vy: Double?
    let direction: String?

    enum CodingKeys: String, CodingKey {
        case id, bbox, label, conf, priority, vx, vy, direction
        case predPath = "pred_path"
    }
}

struct Zone: Codable {
    let x1: Int
    let y1: Int
    let x2: Int
    let y2: Int
}
