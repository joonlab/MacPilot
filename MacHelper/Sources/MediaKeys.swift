import AppKit

/// macOS 시스템 미디어 키(볼륨/밝기 등)를 NSSystemDefined 이벤트로 합성.
/// 네이티브 HUD 가 그대로 뜨고 비공개 API 가 필요 없다.
enum MediaKeys {
    static let soundUp: Int32 = 0
    static let soundDown: Int32 = 1
    static let mute: Int32 = 7
    static let brightnessUp: Int32 = 2
    static let brightnessDown: Int32 = 3

    static func press(_ keyCode: Int32) {
        DispatchQueue.main.async {
            post(keyCode, down: true)
            post(keyCode, down: false)
        }
    }

    private static func post(_ keyCode: Int32, down: Bool) {
        let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
        let data1 = Int((keyCode << 16) | ((down ? 0xa : 0xb) << 8))
        let event = NSEvent.otherEvent(with: .systemDefined,
                                       location: .zero,
                                       modifierFlags: flags,
                                       timestamp: 0,
                                       windowNumber: 0,
                                       context: nil,
                                       subtype: 8,
                                       data1: data1,
                                       data2: -1)
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
