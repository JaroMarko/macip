import Darwin
import MacIPCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct MacIPChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ message: String) throws {
            guard condition else { throw CheckFailure(description: message) }
            count += 1
        }

        for (bytes, expected) in [
            ([UInt8](repeating: 0, count: 4), 0),
            ([255, 255, 255, 0], 24),
            ([255, 255, 255, 254], 31),
            ([255, 255, 255, 255], 32),
            ([UInt8](repeating: 0, count: 16), 0),
            ([UInt8](repeating: 255, count: 8) + [UInt8](repeating: 0, count: 8), 64),
            ([UInt8](repeating: 255, count: 16), 128)
        ] {
            try check(NetworkCollector.prefixLength(bytes: bytes) == expected,
                      "Expected prefix /\(expected) for \(bytes)")
        }
        let invalidMasks: [[UInt8]] = [[255, 0, 255, 0], [255, 255, 253, 0], [127, 0, 0, 0]]
        for bytes in invalidMasks {
            try check(NetworkCollector.prefixLength(bytes: bytes) == nil,
                      "Noncontiguous mask accepted: \(bytes)")
        }

        guard let v4Offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr),
              let v6Offset = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr) else {
            throw CheckFailure(description: "Cannot locate sockaddr address fields")
        }
        func decode(_ storage: [UInt8], family: Int32) -> [UInt8]? {
            storage.withUnsafeBytes { pointer in
                pointer.baseAddress.flatMap { NetworkCollector.maskBytes($0, family: family) }
            }
        }
        // Bytes beyond sa_len are poison and must be ignored.
        var compactV4 = [UInt8](repeating: 255, count: MemoryLayout<sockaddr_in>.size)
        compactV4[0] = UInt8(v4Offset + 3)
        let v4 = decode(compactV4, family: AF_INET)
        try check(v4 == [255, 255, 255, 0], "Compact IPv4 padding failed")
        try check(v4.flatMap { NetworkCollector.prefixLength(bytes: $0) } == 24,
                  "Compact IPv4 /24 failed")

        // This allocation is exactly the compact sockaddr size, shorter than sockaddr_in6.
        var compactV6 = [UInt8](repeating: 255, count: v6Offset + 8)
        compactV6[0] = UInt8(compactV6.count)
        let v6 = decode(compactV6, family: AF_INET6)
        try check(v6 == [UInt8](repeating: 255, count: 8) + [UInt8](repeating: 0, count: 8),
                  "Compact IPv6 padding failed")
        try check(v6.flatMap { NetworkCollector.prefixLength(bytes: $0) } == 64,
                  "Compact IPv6 /64 failed")
        for family in [AF_INET, AF_INET6] {
            let bytes = decode([0], family: family)
            try check(bytes.flatMap { NetworkCollector.prefixLength(bytes: $0) } == 0,
                      "Zero-length mask /0 failed")
        }

        func interface(_ name: String, _ ips: [String] = [], up: Bool = true,
                       wifi: Bool = false, link: Bool? = nil, primary: Bool = false,
                       loopback: Bool = false) -> NetworkInterface {
            NetworkInterface(name: name, label: name, isUp: up, isRunning: up,
                isLoopback: loopback, addresses: ips.map {
                    NetworkAddress(family: $0.contains(":") ? "inet6" : "inet", address: $0,
                                   netmask: nil, prefixLength: nil)
                }, isWiFi: wifi, isLinkActive: link, isPrimary: primary)
        }
        let visibilityCases: [(NetworkInterface, Bool, String)] = [
            (interface("en9", wifi: true, link: false), true, "Disconnected Wi-Fi stays visible"),
            (interface("en12", link: true), true, "Connected Ethernet without IP stays visible"),
            (interface("en4", link: false), false, "Unused Ethernet adapter is hidden"),
            (interface("en2", link: false), false, "Unused Thunderbolt port is hidden"),
            (interface("en2", ["fe80::1"], link: false), false, "Disconnected link-local-only port is hidden"),
            (interface("en2", ["10.0.0.2"], link: false), true, "Assigned IPv4 remains visible even without link"),
            (interface("anpi0"), false, "Internal unaddressed interface is hidden"),
            (interface("awdl0", ["fe80::1%awdl0"], link: true), false, "AWDL link-local is hidden"),
            (interface("llw0", ["fe90::1%llw0"]), false, "Entire IPv6 link-local /10 is recognized"),
            (interface("nan0", ["fe80::1%nan0"], up: false), false, "Inactive NAN is hidden"),
            (interface("utun8", ["fe80::1%utun8"]), false, "Link-local-only tunnel is hidden"),
            (interface("utun4", ["10.5.0.2"]), true, "IPv4 VPN stays visible"),
            (interface("utun8", ["fd00::2"]), true, "IPv6-only ULA VPN stays visible"),
            (interface("en8", ["2001:db8::1"]), true, "IPv6-only network stays visible"),
            (interface("bridge0", ["192.168.2.1"]), true, "Addressed bridge stays visible"),
            (interface("ap1", ["192.168.3.1"]), true, "Internet Sharing stays visible"),
            (interface("en3", ["169.254.1.2"], link: true), true, "DHCP failure address stays visible"),
            (interface("utun3", ["fe80::1"], primary: true), true, "Primary IPv6 tunnel stays visible"),
            (interface("utun2", primary: true), true, "Primary route without IP stays visible"),
            (interface("custom0", ["fe80::1"]), true, "Unknown addressed interface is retained"),
            (interface("custom1"), true, "Unknown active interface is retained"),
            (interface("lo0", ["127.0.0.1"], loopback: true), false, "Loopback is hidden")
        ]
        for (value, expected, message) in visibilityCases {
            try check(value.isRelevant == expected, message)
        }
        let multiple = [interface("en0", ["192.168.1.4"], wifi: true),
                        interface("en7", ["10.0.0.2"], link: true),
                        interface("utun1", ["fd00::1"])]
        try check(multiple.filter(\.isRelevant).count == 3, "Multiple connections are retained")
        try check(interface("en0", ["192.168.1.4", "2001:db8::1", "fe80::1"]).addresses.count == 3,
                  "Filtering does not discard interface addresses")

        let interfaces = try NetworkCollector.collect()
        try check(!interfaces.isEmpty, "No live interfaces collected")
        try check(Set(interfaces.map(\.name)).count == interfaces.count, "Duplicate interface names")
        try check(interfaces.contains {
            $0.isLoopback && $0.addresses.contains { $0.address == "127.0.0.1" }
        }, "IPv4 loopback missing")
        try check(interfaces.allSatisfy { !$0.name.isEmpty && !$0.label.isEmpty },
                  "Interface name or label missing")
        try check(interfaces.flatMap(\.addresses).allSatisfy {
            $0.family == "inet" || $0.family == "inet6"
        }, "Unexpected address family")
        print("Passed \(count) checks.")
    }
}
