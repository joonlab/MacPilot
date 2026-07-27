import Foundation
import SystemConfiguration

enum NetworkInfo {
    /// mDNS .local 호스트네임 (예: "joon-m5-max.local"). IP가 바뀌어도 안 변함.
    static func localHostName() -> String? {
        guard let cf = SCDynamicStoreCopyLocalHostName(nil) else { return nil }
        let name = (cf as String).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : "\(name).local"
    }

    /// LAN IPv4 주소를 반환 (en0 = Wi-Fi 우선). 아이폰에 보여줄 접속 주소용.
    static func primaryIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [String: String] = [:]
        var pointer = ifaddr
        while let ptr = pointer {
            defer { pointer = ptr.pointee.ifa_next }

            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            candidates[name] = String(cString: host)
        }

        return candidates["en0"] ?? candidates["en1"] ?? candidates.values.first
    }

    /// Tailscale IPv4 (100.64.0.0/10 CGNAT 대역). 다른 네트워크·셀룰러에서도 되는 고정 주소.
    static func tailscaleIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var pointer = ifaddr
        while let ptr = pointer {
            defer { pointer = ptr.pointee.ifa_next }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr,
                  (flags & IFF_UP) != 0,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                        &host, socklen_t(host.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: host)
            let parts = ip.split(separator: ".")
            if parts.count == 4, parts[0] == "100",
               let second = Int(parts[1]), (64 ... 127).contains(second) {
                return ip
            }
        }
        return nil
    }
}
