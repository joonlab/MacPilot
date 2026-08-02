import AppKit
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

// johnfkoo951(구요한)님의 CmdPilot 포크에서 이식. 감사합니다.

/// 맥 화면 → 폰/아이패드 실시간 미러링. SCStream(연속 CMSampleBuffer)을 재사용 CIContext로 JPEG 인코딩해
/// 하드롤 WS 바이너리(opcode 0x2)로 밀어낸다. 뷰어 refcount 로 스트림 수명을 관리하고,
/// 뷰어가 0이 되면 자동 정지(화면 기록 인디케이터/CPU 절약).
///
/// 풀 원격데스크톱이 아니라 "경량 뷰어": MJPEG intra-only, 오디오·코덱·델타 없음.
/// 동일 LAN(또는 Tailscale 직결)에서 화면을 보며 탭으로 직접 조작하는 용도.
@available(macOS 14.0, *)
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    static let shared = ScreenStreamer()

    /// 미러 클릭 좌표 매핑용: 현재 스트리밍 중인 디스플레이의 전역(top-left origin) 경계.
    /// EventInjector 가 nx,ny 를 절대 좌표로 환산할 때 읽는다. nil 이면 미러 비활성.
    private(set) var displayBounds: CGRect?

    private let queue = DispatchQueue(label: "com.joonlab.macpilot.mirror", qos: .userInteractive)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])   // Metal 백엔드, 1회 생성 재사용
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private var stream: SCStream?
    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var selectedDisplayID: CGDirectDisplayID?   // nil = 커서 있는 화면 자동
    private var seq: UInt16 = 0

    private final class Viewer {
        weak var conn: HTTPWebSocketConnection?
        var inFlight = false
        init(_ c: HTTPWebSocketConnection) { conn = c }
    }
    private var viewers: [ObjectIdentifier: Viewer] = [:]

    // 적응 파라미터 (폰이 config 로 갱신)
    private var targetLongEdge = 1100
    private var jpegQuality: Double = 0.55
    private var fps = 12

    // MARK: - 공개 API (HelperServer 가 호출)

    func addViewer(_ conn: HTTPWebSocketConnection) {
        queue.async {
            self.viewers[ObjectIdentifier(conn)] = Viewer(conn)
            if self.stream == nil { self.startStream(conn) }
        }
    }

    func removeViewer(_ conn: HTTPWebSocketConnection) {
        queue.async {
            self.viewers[ObjectIdentifier(conn)] = nil
            if self.viewers.isEmpty { self.stopStream() }   // 무뷰어 → 자동 정지
        }
    }

    func configure(longEdge: Int?, fps: Int?, quality: Double?) {
        queue.async {
            if let l = longEdge { self.targetLongEdge = max(480, min(4096, l)) }   // 원본급 미러 옵션 지원(웹 '최대' 화질)
            if let f = fps { self.fps = max(4, min(60, f)) }
            if let q = quality { self.jpegQuality = max(0.3, min(0.95, q)) }
            self.applyConfigLive()
        }
    }

    /// 대상 디스플레이 선택 (멀티모니터). 스트리밍 중이면 해당 화면으로 재시작.
    func selectDisplay(_ id: CGDirectDisplayID?, requester: HTTPWebSocketConnection) {
        queue.async {
            self.selectedDisplayID = id
            if self.stream != nil {
                self.stopStream()
                self.startStream(requester)
            }
        }
    }

    /// 연결된 디스플레이 목록을 폰에 회신 (탭 UI 용).
    func sendDisplays(to conn: HTTPWebSocketConnection) {
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let displays = content?.displays ?? []
            let cur = Self.currentDisplayID()
            var items: [String] = []
            for (i, d) in displays.enumerated() {
                let name = Self.displayName(d.displayID) ?? "디스플레이 \(i + 1)"
                let isMain = d.displayID == CGMainDisplayID()
                let isCur = d.displayID == (self.selectedDisplayID ?? cur)
                items.append("{\"id\":\(d.displayID),\"name\":\"\(name) (\(d.width)×\(d.height))\",\"main\":\(isMain),\"current\":\(isCur)}")
            }
            conn.sendText("{\"t\":\"mirrorDisplays\",\"displays\":[\(items.joined(separator: ","))]}")
        }
    }

    private static func displayName(_ id: CGDirectDisplayID) -> String? {
        for screen in NSScreen.screens {
            if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               CGDirectDisplayID(num.uint32Value) == id {
                return screen.localizedName
            }
        }
        return nil
    }

    // MARK: - 스트림 수명

    private func startStream(_ requester: HTTPWebSocketConnection) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let did = self.selectedDisplayID ?? Self.currentDisplayID()
                guard let display = content.displays.first(where: { $0.displayID == did })
                        ?? content.displays.first else { return }

                let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                let config = self.makeConfig(display: display)

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try await stream.startCapture()

                self.queue.async {
                    self.stream = stream
                    self.displayID = did
                    self.displayBounds = CGDisplayBounds(did)   // top-left 전역 좌표
                    let b = self.displayBounds!
                    let info = "{\"t\":\"mirrorInfo\",\"dispW\":\(Int(b.width)),\"dispH\":\(Int(b.height)),\"fps\":\(self.fps)}"
                    requester.sendText(info)
                }
            } catch {
                requester.sendText(#"{"t":"mirror","error":"화면 기록 권한이 필요합니다. 설정(Settings) → 개인정보 보호 및 보안(Privacy & Security) → 화면 및 시스템 오디오 기록(Screen Recording)에서 MacPilot Helper 를 켜세요."}"#)
            }
        }
    }

    private func stopStream() {
        stream?.stopCapture { _ in }
        stream = nil
        displayBounds = nil
    }

    private func makeConfig(display: SCDisplay) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = min(1.0, Double(targetLongEdge) / Double(max(display.width, display.height)))
        config.width  = Int(Double(display.width)  * scale)
        config.height = Int(Double(display.height) * scale)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))  // FPS 상한
        config.queueDepth = 4
        config.showsCursor = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        return config
    }

    private func applyConfigLive() {
        guard let stream else { return }
        let did = displayID
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content?.displays.first(where: { $0.displayID == did }) else { return }
            try? await stream.updateConfiguration(self.makeConfig(display: display))  // 재시작 없이 해상도/FPS 조정
        }
    }

    // MARK: - SCStreamOutput (연속 프레임)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sb) else { return }

        // .complete 아닌 프레임(.idle/.blank/.suspended)은 버린다 → 정지 화면 대역 0.
        if let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = attach.first?[.status] as? Int,
           let status = SCFrameStatus(rawValue: raw), status != .complete {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }

        // 전송 대상: inFlight 아닌 뷰어만 (백프레셔 → 느린 뷰어의 프레임 통째 드롭)
        let ready = viewers.values.filter { !$0.inFlight && $0.conn != nil }
        if ready.isEmpty { return }   // 아무도 못 받을 상태면 인코딩조차 안 함 (CPU 절약)

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let jpeg = ciContext.jpegRepresentation(
            of: ciImage, colorSpace: colorSpace,
            options: [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): jpegQuality]
        ) else { return }

        seq &+= 1
        var packet = Data(capacity: 8 + jpeg.count)
        packet.append(0x4D)                                   // magic 'M'
        packet.append(0x01)                                   // flags: keyframe
        withUnsafeBytes(of: seq.littleEndian) { packet.append(contentsOf: $0) }
        let tMs = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970 * 1000))
        withUnsafeBytes(of: tMs.littleEndian) { packet.append(contentsOf: $0) }
        packet.append(jpeg)

        for viewer in ready {
            viewer.inFlight = true
            viewer.conn?.sendBinary(packet) { [weak self, weak viewer] _ in
                self?.queue.async { viewer?.inFlight = false }   // 플러시 완료 → 다음 프레임 허용
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 디스플레이 구성 변경/잠금 등으로 중단되면 뷰어가 남아 있을 때 재시작
        queue.async {
            self.stream = nil
            self.displayBounds = nil
            if let anyViewer = self.viewers.values.first(where: { $0.conn != nil })?.conn {
                self.startStream(anyViewer)
            }
        }
    }

    private static func currentDisplayID() -> CGDirectDisplayID {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
           let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return CGDirectDisplayID(num.uint32Value)
        }
        return CGMainDisplayID()
    }
}
