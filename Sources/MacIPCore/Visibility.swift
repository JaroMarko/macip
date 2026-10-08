import Darwin

extension NetworkAddress {
    public var isLinkLocal: Bool {
        if family == "inet" { return address.hasPrefix("169.254.") }
        guard family == "inet6" else { return false }
        var value = in6_addr()
        let host = String(address.split(separator: "%", maxSplits: 1).first ?? "")
        guard host.withCString({ inet_pton(AF_INET6, $0, &value) }) == 1 else { return false }
        return withUnsafeBytes(of: value) { $0[0] == 0xfe && ($0[1] & 0xc0) == 0x80 }
    }

    var isRelevantAddress: Bool {
        if family == "inet" {
            return !address.hasPrefix("127.") && address != "0.0.0.0"
        }
        return family == "inet6" && !isLinkLocal && address != "::" && address != "::1"
    }
}

extension NetworkInterface {
    /// Keep configured Wi-Fi, connected links, assigned addresses and primary routes.
    /// Unknown interface types are retained conservatively; --all bypasses this policy.
    public var isRelevant: Bool {
        if isLoopback { return false }
        if isPrimary || isWiFi || addresses.contains(where: \.isRelevantAddress) { return true }
        let auxiliary = ["anpi", "awdl", "llw", "nan", "utun", "ap"].contains { prefix in
            name.hasPrefix(prefix) && name.dropFirst(prefix.count).allSatisfy(\.isNumber)
        }
        if auxiliary || isLinkActive == false { return false }
        if isLinkActive == true { return true }
        if !addresses.isEmpty { return true }
        return isLinkActive == nil && isUp
    }
}
