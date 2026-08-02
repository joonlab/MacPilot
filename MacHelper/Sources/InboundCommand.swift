import Foundation

/// 브라우저(JS)가 WebSocket 으로 보내는 명령. 웹 친화적인 평평한 JSON 형태.
///
/// 예) {"t":"move","dx":3,"dy":-2}
///     {"t":"down","button":"left"}          // 드래그 시작(버튼 누름)
///     {"t":"up","button":"left"}            // 드래그 끝(버튼 뗌)
///     {"t":"click","button":"left","count":2}  // 더블클릭
///     {"t":"scroll","dx":0,"dy":12}
///     {"t":"key","keyCode":49,"mods":["command"]}
struct InboundCommand: Decodable {
    let t: String
    let dx: Double?
    let dy: Double?
    let button: String?
    let count: Int?
    let keyCode: Int?
    let mods: [String]?
    let name: String?
    let target: String?   // "launch" 액션용: 앱 경로(/...) 또는 앱 이름
    let dir: String?      // "gesture" 액션용: up/down/left/right (3손가락 스와이프)
    let text: String?     // "text" 액션용: 입력할 문자열 (한글/이모지 포함)
    let steps: [MacroStep]? // "macro" 액션용: 순차 실행 단계
    let deckJson: String? // "saveDeck" 액션용: 덱 전체 JSON 문자열
    // 화면 미러링
    let action: String?   // "mirror" 액션: start / stop / config / displays / select
    let nx: Double?       // 미러 절대좌표(정규화 0..1, x)
    let ny: Double?       // 미러 절대좌표(정규화 0..1, y)
    let w: Int?           // mirror config: 긴 변 목표 px
    let fps: Int?         // mirror config: 목표 프레임레이트
    let q: Double?        // mirror config: JPEG 품질 0..1
    let display: Int?     // mirror: 대상 디스플레이 ID (없으면 커서 있는 화면)
}

/// 매크로 한 단계. type 에 따라 사용하는 필드가 다르다.
///   key   → keyCode, mods
///   text  → text
///   launch→ target
///   delay → ms
struct MacroStep: Decodable {
    let type: String
    let keyCode: Int?
    let mods: [String]?
    let text: String?
    let target: String?
    let ms: Int?
}
