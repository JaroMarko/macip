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
