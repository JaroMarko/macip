import Darwin
import Foundation
import SystemConfiguration

public struct NetworkAddress: Equatable, Sendable {
    public let family: String
    public let address: String
    public let netmask: String?
    public let prefixLength: Int?

    public init(family: String, address: String, netmask: String?, prefixLength: Int?) {
        self.family = family
        self.address = address
        self.netmask = netmask
        self.prefixLength = prefixLength
    }
}

public struct NetworkInterface: Equatable, Sendable {
    public let name: String
    public let label: String
    public let isUp: Bool
    public let isRunning: Bool
    public let isLoopback: Bool
    public let addresses: [NetworkAddress]

    public init(name: String, label: String, isUp: Bool, isRunning: Bool,
                isLoopback: Bool, addresses: [NetworkAddress]) {
        self.name = name
        self.label = label
        self.isUp = isUp
        self.isRunning = isRunning
        self.isLoopback = isLoopback
        self.addresses = addresses
    }
}

public enum NetworkCollector {
    public static func collect() throws -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { if let head { freeifaddrs(head) } }

        let labels = interfaceLabels()
        var records: [String: (flags: UInt32, addresses: [NetworkAddress])] = [:]
        var current = head
        while let node = current {
            let entry = node.pointee
            current = entry.ifa_next
            guard let namePointer = entry.ifa_name else { continue }
            let name = String(cString: namePointer)
            var record = records[name] ?? (flags: 0, addresses: [])
            record.flags |= entry.ifa_flags
            if let address = entry.ifa_addr,
               let value = networkAddress(address, mask: entry.ifa_netmask),
               !record.addresses.contains(value) {
                record.addresses.append(value)
            }
            records[name] = record
        }

        return records.keys.sorted().compactMap { name in
            guard let record = records[name] else { return nil }
            return NetworkInterface(
                name: name, label: labels[name] ?? (name.hasPrefix("utun") ? "Tunnel" : name),
                isUp: record.flags & UInt32(IFF_UP) != 0,
                isRunning: record.flags & UInt32(IFF_RUNNING) != 0,
                isLoopback: record.flags & UInt32(IFF_LOOPBACK) != 0,
                addresses: record.addresses.sorted {
                    ($0.family, $0.address) < ($1.family, $1.address)
                }
            )
        }
    }

    // A prefix is valid only when all one bits precede all zero bits.
    public static func prefixLength(bytes: [UInt8]) -> Int? {
        var count = 0
        var sawZero = false
        for byte in bytes {
            for bit in (0..<8).reversed() {
                if byte & (UInt8(1) << bit) == 0 {
                    sawZero = true
                } else {
                    guard !sawZero else { return nil }
                    count += 1
                }
            }
        }
        return count
    }

    private static func interfaceLabels() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }
        var labels: [String: String] = [:]
        for interface in interfaces {
            if let name = SCNetworkInterfaceGetBSDName(interface),
               let label = SCNetworkInterfaceGetLocalizedDisplayName(interface) {
                labels[name as String] = label as String
            }
        }
        return labels
    }

    private static func networkAddress(_ address: UnsafePointer<sockaddr>,
                                       mask: UnsafePointer<sockaddr>?) -> NetworkAddress? {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6,
              let host = numericHost(address) else { return nil }
        var maskText: String?
        var prefix: Int?
        if let mask, let bytes = maskBytes(UnsafeRawPointer(mask), family: family) {
            if family == AF_INET {
                maskText = bytes.map(String.init).joined(separator: ".")
            }
            prefix = prefixLength(bytes: bytes)
        }
        return NetworkAddress(family: family == AF_INET ? "inet" : "inet6",
                              address: host, netmask: maskText, prefixLength: prefix)
    }

    /// Restores a compact BSD netmask to its full address bytes.
    /// The pointer must reference at least max(1, sa_len) readable bytes.
    /// Omitted trailing address bytes are zeroes.
    public static func maskBytes(_ mask: UnsafeRawPointer, family: Int32) -> [UInt8]? {
        let offset: Int?
        let count: Int
        switch family {
        case AF_INET:
            offset = MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)
            count = MemoryLayout<in_addr>.size
        case AF_INET6:
            offset = MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)
            count = MemoryLayout<in6_addr>.size
        default:
            return nil
        }
        guard let offset else { return nil }
        let length = Int(mask.load(as: UInt8.self))
        let available = min(count, max(0, length - offset))
        var bytes = [UInt8](repeating: 0, count: count)
        for index in 0..<available {
            bytes[index] = mask.load(fromByteOffset: offset + index, as: UInt8.self)
        }
        return bytes
    }

    private static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        let length = socklen_t(address.pointee.sa_len)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = buffer.withUnsafeMutableBufferPointer {
            getnameinfo(address, length, $0.baseAddress, socklen_t($0.count), nil, 0, NI_NUMERICHOST)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return nil }
            return String(cString: base)
        }
    }
}
