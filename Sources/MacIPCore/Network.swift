import Darwin
import Foundation
import Dispatch
import SystemConfiguration
import IOKit

public struct NetworkAddress: Equatable, Sendable {
    public let family: String
    public let address: String
    public let netmask: String?
    public let prefixLength: Int?
    public let broadcast: String?

    public init(family: String, address: String, netmask: String?, prefixLength: Int?, broadcast: String? = nil) {
        self.family = family
        self.address = address
        self.netmask = netmask
        self.prefixLength = prefixLength
        self.broadcast = broadcast
    }
}

public struct NetworkInterface: Equatable, Sendable {
    public let name: String
    public let label: String
    public let isUp: Bool
    public let isRunning: Bool
    public let isLoopback: Bool
    public let addresses: [NetworkAddress]
    public let isHardwareEthernet: Bool
    public let isWiFi: Bool
    public let isLinkActive: Bool?
    public let isPrimary: Bool
    public let macAddress: String?
    public let macIsHardware: Bool

    public init(name: String, label: String, isUp: Bool, isRunning: Bool,
                isLoopback: Bool, addresses: [NetworkAddress],
                isWiFi: Bool = false, isLinkActive: Bool? = nil, isPrimary: Bool = false,
                macAddress: String? = nil, macIsHardware: Bool = false,
                isHardwareEthernet: Bool = false) {
        self.name = name
        self.label = label
        self.isUp = isUp
        self.isRunning = isRunning
        self.isLoopback = isLoopback
        self.addresses = addresses
        self.isHardwareEthernet = isHardwareEthernet
        self.isWiFi = isWiFi
        self.isLinkActive = isLinkActive
        self.isPrimary = isPrimary
        self.macAddress = macAddress
        self.macIsHardware = macIsHardware
    }
}

public enum NetworkCollector {
    public static func collect() throws -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { if let head { freeifaddrs(head) } }

        let metadata = interfaceMetadata()
        let hardwareEthernet = hardwareEthernetNames().intersection(metadata.ethernet)
        // Fetch link and primary-route state in one snapshot, rather than opening
        // a temporary dynamic-store session for each interface.
        let store = SCDynamicStoreCreate(nil, "macip" as CFString, nil, nil)
        let state = store.flatMap {
            SCDynamicStoreCopyMultiple($0,
                ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray,
                ["State:/Network/Interface/.*/Link"] as CFArray) as? [String: Any]
        } ?? [:]
        let primary = Set(["IPv4", "IPv6"].compactMap { family -> String? in
            let value = state["State:/Network/Global/\(family)"] as? [String: Any]
            return value?["PrimaryInterface"] as? String
        })
        var records: [String: (flags: UInt32, addresses: [NetworkAddress], mac: String?)] = [:]
        var current = head
        while let node = current {
            let entry = node.pointee
            current = entry.ifa_next
            guard let namePointer = entry.ifa_name else { continue }
            let name = String(cString: namePointer)
            var record = records[name] ?? (flags: 0, addresses: [], mac: nil)
            record.flags |= entry.ifa_flags
            if let address = entry.ifa_addr {
                if Int32(address.pointee.sa_family) == AF_LINK {
                    record.mac = hardwareAddress(UnsafeRawPointer(address)) ?? record.mac
                } else {
                    var broadcast: String?
                    if Int32(address.pointee.sa_family) == AF_INET,
                       entry.ifa_flags & UInt32(IFF_BROADCAST) != 0,
                       let destination = entry.ifa_dstaddr,
                       Int32(destination.pointee.sa_family) == AF_INET {
                        broadcast = numericHost(destination)
                    }
                    if let value = networkAddress(address, mask: entry.ifa_netmask, broadcast: broadcast),
                       !record.addresses.contains(value) {
                        record.addresses.append(value)
                    }
                }
            }
            records[name] = record
        }

        let needsCurrentMAC = records.contains { name, record in
            metadata.wifi.contains(name) || record.mac == "02:00:00:00:00:00"
        }
        let currentMACs = needsCurrentMAC ? currentHardwareAddresses() : [:]

        return records.keys.sorted().compactMap { name in
            guard let record = records[name] else { return nil }
            let link = state["State:/Network/Interface/\(name)/Link"] as? [String: Any]
            // macOS may redact Wi-Fi MAC in getifaddrs. ifconfig reports the current
            // address, including Private Wi-Fi Address; hardware metadata may not.
            let needsCurrentMAC = metadata.wifi.contains(name) || record.mac == "02:00:00:00:00:00"
            let currentMAC = needsCurrentMAC ? currentMACs[name] : record.mac
            let mac = currentMAC ?? metadata.hardware[name]
            return NetworkInterface(
                name: name, label: metadata.labels[name] ?? (name.hasPrefix("utun") ? "Tunnel" : name),
                isUp: record.flags & UInt32(IFF_UP) != 0,
                isRunning: record.flags & UInt32(IFF_RUNNING) != 0,
                isLoopback: record.flags & UInt32(IFF_LOOPBACK) != 0,
                addresses: record.addresses.sorted {
                    ($0.family, $0.address) < ($1.family, $1.address)
                },
                isWiFi: metadata.wifi.contains(name),
                isLinkActive: link?["Active"] as? Bool,
                isPrimary: primary.contains(name),
                macAddress: mac,
                macIsHardware: currentMAC == nil && mac != nil,
                isHardwareEthernet: hardwareEthernet.contains(name)
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

    // Walk every Ethernet interface's provider chain, including nested docks.
    // USB host devices and PCIe Ethernet controllers represent physical ports.
    // Reject virtual/device-mode providers before considering an upstream PCI bus.
    private static func hardwareEthernetNames() -> Set<String> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                IOServiceMatching("IOEthernetInterface"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var names = Set<String>()
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let name = IORegistryEntryCreateCFProperty(entry, "BSD Name" as CFString,
                                                       kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            var providers: [String] = []
            var node = entry
            while node != 0 {
                for type in ["AppleThunderboltIPPort", "IOUSBDeviceInterface",
                             "IOUSBHostDevice", "IOUSBDevice", "IOPCIDevice"] {
                    if IOObjectConformsTo(node, type) != 0 {
                        providers.append(type)
                        break
                    }
                }
                // The nearest recognized provider decides the result; upstream
                // hubs/controllers cannot change it.
                if !providers.isEmpty {
                    IOObjectRelease(node)
                    break
                }
                var parent: io_registry_entry_t = 0
                let status = IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent)
                IOObjectRelease(node)
                node = status == KERN_SUCCESS ? parent : 0
            }
            if let name, hasPhysicalEthernetProvider(providers) { names.insert(name) }
            entry = IOIteratorNext(iterator)
        }
        return names
    }

    /// Provider classes are ordered from the interface toward the registry root.
    public static func hasPhysicalEthernetProvider(_ classes: [String]) -> Bool {
        for type in classes {
            switch type {
            case "AppleThunderboltIPPort", "IOUSBDeviceInterface": return false
            case "IOUSBHostDevice", "IOUSBDevice", "IOPCIDevice": return true
            default: continue
            }
        }
        return false
    }

    private static func interfaceMetadata() -> (labels: [String: String], wifi: Set<String>, ethernet: Set<String>, hardware: [String: String]) {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return ([:], [], [], [:])
        }
        var labels: [String: String] = [:]
        var wifi = Set<String>()
        var ethernet = Set<String>()
        var hardware: [String: String] = [:]
        for interface in interfaces {
            if let name = SCNetworkInterfaceGetBSDName(interface),
               let value = SCNetworkInterfaceGetHardwareAddressString(interface),
               (value as String).lowercased() != "02:00:00:00:00:00" {
                hardware[name as String] = (value as String).lowercased()
            }
            if let name = SCNetworkInterfaceGetBSDName(interface),
               SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIEEE80211 {
                wifi.insert(name as String)
            }
            if let name = SCNetworkInterfaceGetBSDName(interface),
               SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeEthernet {
                ethernet.insert(name as String)
            }
            if let name = SCNetworkInterfaceGetBSDName(interface),
               let label = SCNetworkInterfaceGetLocalizedDisplayName(interface) {
                labels[name as String] = label as String
            }
        }
        return (labels, wifi, ethernet, hardware)
    }

    private static func networkAddress(_ address: UnsafePointer<sockaddr>,
                                       mask: UnsafePointer<sockaddr>?,
                                       broadcast: String?) -> NetworkAddress? {
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
                              address: host, netmask: maskText, prefixLength: prefix, broadcast: broadcast)
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

    /// Reads the current six-byte MAC from an AF_LINK sockaddr, including variable-length names.
    /// The pointer must reference at least max(1, sdl_len) readable bytes.
    public static func hardwareAddress(_ link: UnsafeRawPointer) -> String? {
        let length = Int(link.load(as: UInt8.self))
        guard let nameOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_nlen),
              let addressOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_alen),
              let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data),
              length > max(nameOffset, addressOffset) else { return nil }
        let nameLength = Int(link.load(fromByteOffset: nameOffset, as: UInt8.self))
        let addressLength = Int(link.load(fromByteOffset: addressOffset, as: UInt8.self))
        let start = dataOffset + nameLength
        guard addressLength == 6, start + addressLength <= length else { return nil }
        return (0..<addressLength).map {
            String(format: "%02x", link.load(fromByteOffset: start + $0, as: UInt8.self))
        }.joined(separator: ":")
    }

    private static func currentHardwareAddresses() -> [String: String] {
        guard let data = readCommandOutput(executable: "/sbin/ifconfig", arguments: ["-a"]),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        return parseHardwareAddresses(text)
    }

    /// Read a trusted leaf command without a shell. The deadline sends SIGTERM
    /// during pipe draining or completion; the command must honor SIGTERM and
    /// must not leave descendants holding stdout open (as with /sbin/ifconfig).
    public static func readCommandOutput(executable: String, arguments: [String],
                                         timeout: Double = 1) -> Data? {
        guard timeout > 0, timeout.isFinite else { return nil }
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        // Drain first so a large interface list cannot fill the pipe and block
        // the child. The deadline terminates ifconfig if its read ever stalls.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        finished.wait()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return nil }
        return data
    }

    public static func parseHardwareAddresses(_ text: String) -> [String: String] {
        var addresses: [String: String] = [:]
        var name: String?
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = fields.first else { continue }
            if line.first?.isWhitespace == false {
                name = first.hasSuffix(":") ? String(first.dropLast()) : nil
                continue
            }
            guard let name, fields.count >= 2, first == "ether" else { continue }
            let value = fields[1].lowercased()
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 6,
                  parts.allSatisfy({ $0.count == 2 && $0.allSatisfy { "0123456789abcdef".contains($0) } }),
                  value != "02:00:00:00:00:00" else { continue }
            addresses[name] = value
        }
        return addresses
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
