import AVFoundation
import SwiftUI

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var streamer = CameraStreamer()

    private var status: String {
        if streamer.cameraDenied { return "Camera access is off. Enable it in Settings > MyCam." }
        if !streamer.isStreaming { return "Tap Start, then connect from the PC app." }
        let pc = streamer.clientCount == 0 ? "Waiting for the PC app..." : "PC connected"
        return "\(pc)\nWi-Fi address: \(streamer.wifiAddress)"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: streamer.session).ignoresSafeArea()
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    Text(status)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 12) {
                        Button(streamer.isStreaming ? "Stop" : "Start") {
                            streamer.isStreaming ? streamer.stopServer() : streamer.startServer()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(streamer.isStreaming ? .red : .blue)
                        Button("Flip camera") { streamer.flipCamera() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
        }
        .onAppear { streamer.startCamera() }
    }
}
