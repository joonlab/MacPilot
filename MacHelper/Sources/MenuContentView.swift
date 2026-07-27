import CoreImage.CIFilterBuiltins
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var server: HelperServer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MacPilot 헬퍼")
                .font(.headline)

            // 서버 상태
            HStack(spacing: 6) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(server.isRunning ? "실행 중" : "시작 실패 · 포트 확인")
                    .font(.callout)
            }

            if server.isRunning {
                // 접속 주소 + QR
                Text("아이폰 사파리로 접속하거나 카메라로 QR을 스캔하세요")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let qr = Self.makeQR(server.httpURL) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 140, height: 140)
                        .frame(maxWidth: .infinity, alignment: .center)
                }

                HStack {
                    Text(server.httpURL)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("복사") { server.copyURL() }
                }
                if !server.ipFallback.isEmpty {
                    Text(server.ipFallback)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }

                // 외부(다른 네트워크·셀룰러) 접속용 Tailscale 주소
                if !server.tailscaleURL.isEmpty {
                    Divider()
                    Text("🌐 외부에서 접속 (Tailscale)")
                        .font(.caption).bold()
                    Text("호텔·셀룰러 등 다른 네트워크에서도 접속 · 양쪽 Tailscale 켜기")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let qr = Self.makeQR(server.tailscaleURL) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 120, height: 120)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    HStack {
                        Text(server.tailscaleURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("복사") { server.copy(server.tailscaleURL) }
                    }
                }

                Label(server.activeClients > 0 ? "연결됨: \(server.activeClients)대" : "대기 중",
                      systemImage: server.activeClients > 0 ? "iphone.radiowaves.left.and.right" : "iphone.slash")
                    .font(.callout)
                    .foregroundStyle(server.activeClients > 0 ? .green : .secondary)

                // 진단: 명령 수가 늘면 '도착은 함' → 안 움직이면 권한 문제
                Text("받은 명령: \(server.commandCount)  (\(server.lastCommand))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // 손쉬운 사용 권한
            HStack(spacing: 6) {
                Image(systemName: server.accessibilityGranted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(server.accessibilityGranted ? .green : .orange)
                Text(server.accessibilityGranted ? "손쉬운 사용 권한 OK" : "손쉬운 사용 권한 필요")
                    .font(.callout)
            }
            if !server.accessibilityGranted {
                Text("이 권한이 없으면 마우스/키보드가 실제로 움직이지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("권한 요청 / 설정 열기") {
                    server.promptAccessibility()
                    server.openAccessibilitySettings()
                }
            }
            Button("권한 상태 새로고침") {
                server.refreshAccessibility()
            }

            Divider()

            // PIN 페어링 (같은 Wi-Fi의 타인 접속 차단)
            Toggle(isOn: Binding(get: { server.pairingEnabled },
                                 set: { server.setPairing($0) })) {
                Text("PIN 페어링").font(.callout)
            }
            if server.pairingEnabled {
                Text("폰에서 접속 시 아래 PIN을 입력해야 합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(server.pairingPin)
                        .font(.system(.title2, design: .monospaced))
                        .bold()
                        .textSelection(.enabled)
                    Spacer()
                    Button("새 PIN") { server.regeneratePairingPin() }
                }
            } else {
                Text("켜면 같은 Wi-Fi의 다른 사람이 함부로 접속·조작하지 못합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear { server.refreshAccessibility() }
    }

    /// 문자열을 QR 코드 NSImage 로 변환
    static func makeQR(_ string: String) -> NSImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
