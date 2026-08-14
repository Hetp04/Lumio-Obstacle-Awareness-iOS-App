import SwiftUI

struct DetectionOverlayView: View {
    let tracks: [Track]

    let imageResolution: CGSize

    private var imageWidth: CGFloat {
        max(1, imageResolution.width)
    }
    private var imageHeight: CGFloat {
        max(1, imageResolution.height)
    }

    var body: some View {
        GeometryReader { geometry in
            ForEach(tracks) { track in
                drawTrack(for: track, in: geometry.size)
            }
        }
    }

    private func scalePoint(_ point: CGPoint, in viewSize: CGSize) -> CGPoint {
        let scaleX = viewSize.width / imageWidth
        let scaleY = viewSize.height / imageHeight

        let scale = max(scaleX, scaleY)

        let offsetX = (viewSize.width - (imageWidth * scale)) / 2.0
        let offsetY = (viewSize.height - (imageHeight * scale)) / 2.0

        let scaledX = (point.x * scale) + offsetX
        let scaledY = (point.y * scale) + offsetY

        return CGPoint(x: scaledX, y: scaledY)
    }

    @ViewBuilder
    private func drawTrack(for track: Track, in viewSize: CGSize) -> some View {

        let p1 = scalePoint(CGPoint(x: track.bbox[0], y: track.bbox[1]), in: viewSize)
        let p2 = scalePoint(CGPoint(x: track.bbox[2], y: track.bbox[3]), in: viewSize)

        let width = p2.x - p1.x
        let height = p2.y - p1.y
        let midX = p1.x + (width / 2)

        let color = (track.priority == "high") ? Color.red : (track.priority == "medium" ? Color.yellow : Color.green)

        Rectangle()
            .stroke(color, lineWidth: 2)
            .frame(width: width, height: height)
            .position(x: midX, y: p1.y + (height / 2))

        Text("ID:\(track.id) \(track.label ?? "obj")")
            .font(.system(size: 12, weight: .semibold))
            .padding(2)
            .background(color)
            .foregroundColor(.black)
            .position(x: midX, y: p1.y - 10)

        if let predPath = track.predPath, predPath.count >= 2 {
            Path { path in
                guard let firstRawPoint = predPath.first else { return }
                let firstPoint = scalePoint(CGPoint(x: firstRawPoint[0], y: firstRawPoint[1]), in: viewSize)
                path.move(to: firstPoint)

                for point in predPath.dropFirst() {
                    let scaledP = scalePoint(CGPoint(x: point[0], y: point[1]), in: viewSize)
                    path.addLine(to: scaledP)
                }
            }
            .stroke(Color.cyan, lineWidth: 2)
        }
    }
}
