// Captures the iPhone camera and serves it as an MJPEG stream on TCP port 4747.
// The PC app connects either over USB (through Apple's usbmuxd) or over Wi-Fi.

import AVFoundation
import CoreImage
import ImageIO
import Network
import UIKit

final class CameraStreamer: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var isStreaming = false
    @Published var clientCount = 0
    @Published var wifiAddress = "Not on Wi-Fi"
    @Published var cameraDenied = false

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "mycam.camera")
    private let ciContext = CIContext()
    private let port: UInt16 = 4747
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: Client] = [:]
    private let lock = NSLock()
    private var configured = false
    private var usingFront = false

    private final class Client {
        let conn: NWConnection
        var ready = false   // the PC sent its request and got the HTTP header
        var inFlight = 0    // frames queued but not yet written (used to drop frames, not lag)
        init(_ conn: NWConnection) { self.conn = conn }
    }

    // MARK: camera

    func startCamera() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { self.cameraDenied = !granted }
            guard granted else { return }
            self.queue.async {
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        addInput(front: false)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        applyOrientation(output)
        session.commitConfiguration()
        configured = true
    }

    private func addInput(front: Bool) {
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
    }

    private func applyOrientation(_ output: AVCaptureVideoDataOutput) {
        guard let connection = output.connection(with: .video) else { return }
        // Landscape frames; the PC app can rotate/flip them with the Transform menu.
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
    }

    func flipCamera() {
        queue.async {
            self.usingFront.toggle()
            self.session.beginConfiguration()
            for input in self.session.inputs { self.session.removeInput(input) }
            self.addInput(front: self.usingFront)
            if let output = self.session.outputs.first as? AVCaptureVideoDataOutput {
                self.applyOrientation(output)
            }
            self.session.commitConfiguration()
        }
    }

    // MARK: server

    func startServer() {
        guard listener == nil else { return }
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: .global())
            listener = l
        } catch {
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true   // iOS pauses the camera if the screen locks
        wifiAddress = Self.wifiIPAddress() ?? "Not on Wi-Fi"
        isStreaming = true
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let all = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        all.forEach { $0.conn.cancel() }
        UIApplication.shared.isIdleTimerDisabled = false
        isStreaming = false
        clientCount = 0
    }

    private func accept(_ conn: NWConnection) {
        let client = Client(conn)
        let id = ObjectIdentifier(client)
        lock.lock(); clients[id] = client; lock.unlock()
        publishClientCount()
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.remove(id)
            default: break
            }
        }
        conn.start(queue: .global())
        // Wait for the PC's HTTP request, then answer with the multipart header.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard error == nil, data != nil else { self?.remove(id); return }
            let header = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(header.utf8), completion: .contentProcessed { _ in client.ready = true })
        }
    }

    private func remove(_ id: ObjectIdentifier) {
        lock.lock()
        let client = clients.removeValue(forKey: id)
        lock.unlock()
        client?.conn.cancel()
        publishClientCount()
    }

    private func publishClientCount() {
        lock.lock(); let n = clients.count; lock.unlock()
        DispatchQueue.main.async { self.clientCount = n }
    }

    // MARK: frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lock.lock()
        let targets = clients.filter { $0.value.ready && $0.value.inFlight < 2 }
        lock.unlock()
        guard !targets.isEmpty, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let image = CIImage(cvPixelBuffer: pixels)
        guard let jpeg = ciContext.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.7]
        ) else { return }

        var packet = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
        packet.append(jpeg)
        packet.append(Data("\r\n".utf8))

        for (id, client) in targets {
            lock.lock(); client.inFlight += 1; lock.unlock()
            client.conn.send(content: packet, completion: .contentProcessed { [weak self] error in
                self?.lock.lock(); client.inFlight -= 1; self?.lock.unlock()
                if error != nil { self?.remove(id) }
            })
        }
    }

    // MARK: helpers

    private static func wifiIPAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: ifa.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }
        return nil
    }
}
