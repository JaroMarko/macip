import Darwin
import Foundation
import MacIPCore
import SystemConfiguration

private let version = "0.2.2"

private enum CLIError: Error, CustomStringConvertible {
    case usage(String)
    var description: String {
        switch self {
        case .usage(let message): return message
        }
    }
}

private struct Options {
    var route = false
    var color = false
    var showAll = false
    var interfaceName: String?
    var help = false
    var version = false
}

private func usage() -> String {
    """
    Usage: macip [--help] [--version] [-c|--color] a|addr|address [show NAME] [--all]

    Show local interface addresses. With no arguments, behaves like `macip address`.
    Shows Wi-Fi, connected links and interfaces with relevant addresses or primary routes.
    Use --all to include every interface, including loopback.
    macip route shows primary service routes for IPv4 and IPv6.
    """
}

private func parse(_ arguments: [String]) throws -> Options {
    if arguments.contains("--help") || arguments.contains("-h") { return Options(help: true) }
    if arguments.contains("--version") || arguments.contains("-v") { return Options(version: true) }

    var options = Options()
    var positional: [String] = []
    for argument in arguments {
        switch argument {
        case "-c", "--color": options.color = true
        case "--all": options.showAll = true
        case "--help", "-h", "--version", "-v": break
        default:
            if argument.hasPrefix("-") {
                throw CLIError.usage("Unknown option: \(safe(argument))\n\n\(usage())")
            }
            positional.append(argument)
        }
    }

    if positional.isEmpty { return options }
    if positional == ["route"] { options.route = true; return options }
    guard ["a", "addr", "address"].contains(positional[0]) else {
        throw CLIError.usage("Unsupported command: \(safe(positional[0]))\n\n\(usage())")
    }
    if positional.count == 1 { return options }
    guard positional.count == 3, positional[1] == "show", !positional[2].isEmpty else {
        throw CLIError.usage("Expected: address [show NAME]\n\n\(usage())")
    }
    options.interfaceName = positional[2]
    return options
}

// Replace control characters so labels and addresses cannot alter terminal output.
private func safe(_ value: String) -> String {
    value.unicodeScalars.map { scalar in
        CharacterSet.controlCharacters.contains(scalar) ? "�" : String(scalar)
    }.joined()
}

private struct Style {
    let enabled: Bool
    func paint(_ text: String, code: String) -> String {
        enabled ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
    }
}

private func field(_ label: String, _ value: String, color: String, style: Style) {
    let padding = String(repeating: " ", count: max(1, 10 - label.count))
    print("    \(label)\(padding)\(style.paint(safe(value), code: color))")
}

private func showAddress(_ address: NetworkAddress, interfaceName: String, style: Style) {
    let prefix = address.prefixLength.map { "/\($0)" } ?? ""
    let scope = address.isLinkLocal ? " · link-local" : ""
    let isIPv4 = address.family == "inet"
    let host = isIPv4 ? address.address : String(address.address.split(separator: "%", maxSplits: 1).first ?? "")
    field(isIPv4 ? "IPv4" : "IPv6", host + prefix + scope,
          color: isIPv4 ? "1;35" : "1;34", style: style)
    if !isIPv4 && address.isLinkLocal {
        let target = address.address.contains("%") ? address.address : host + "%" + interfaceName
        field("Ping", target, color: "90", style: style)
    }
    if isIPv4, let mask = address.netmask { field("Mask", mask, color: "0", style: style) }
    if isIPv4, let broadcast = address.broadcast {
        field("Broadcast", broadcast, color: "1;35", style: style)
    }
}

private func run() throws {
    let options = try parse(Array(CommandLine.arguments.dropFirst()))
    if options.help { print(usage()); return }
    if options.version { print("macip \(version)"); return }

    if options.route { showRoutes(); return }

    let term = getenv("TERM").map { String(cString: $0) }
    let style = Style(enabled: options.color && isatty(STDOUT_FILENO) != 0
                      && getenv("NO_COLOR") == nil && term != nil && term != "dumb")
    let interfaces = try NetworkCollector.collect()
    if let name = options.interfaceName, !interfaces.contains(where: { $0.name == name }) {
        throw CLIError.usage("No interface named \(safe(name)).")
    }

    let visible = interfaces.filter { interface in
        if let name = options.interfaceName { return interface.name == name }
        if options.showAll { return true }
        return interface.isRelevant
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    for (index, interface) in visible.enumerated() {
        if index > 0 { print() }
        let state = !interface.isUp ? "DOWN" : interface.isLinkActive == false ? "NO LINK"
            : interface.addresses.isEmpty ? "NO IP" : "UP"
        let stateColor = state == "UP" ? "32" : state == "NO IP" ? "33" : "90"
        print("\(style.paint(safe(interface.name), code: "1;36")) · \(safe(interface.label)) · \(style.paint(state, code: stateColor))")
        if let mac = interface.macAddress {
            field("MAC", mac + (interface.macIsHardware ? " · hardware" : ""), color: "1;33", style: style)
        }
        else if interface.isWiFi { field("MAC", "unavailable", color: "90", style: style) }
        if interface.addresses.isEmpty {
            print("    (no IP address)")
        } else {
            for address in interface.addresses { showAddress(address, interfaceName: interface.name, style: style) }
        }
    }
    let hidden = interfaces.count - visible.count
    if options.interfaceName == nil && hidden > 0 { print("\n\(hidden) interfaces hidden; use --all to show them.") }
}

private func showRoutes() {
    print("Primary service routes (not the full routing table)")
    for family in ["IPv4", "IPv6"] {
        let key = "State:/Network/Global/\(family)" as CFString
        guard let value = SCDynamicStoreCopyValue(nil, key) as? [String: Any] else {
            print("\(family): unavailable")
            continue
        }
        let name = value["PrimaryInterface"] as? String ?? "unknown"
        let router = value["Router"] as? String ?? "unavailable"
        print("\(family): via \(safe(router)) dev \(safe(name))")
    }
}

do {
    try run()
} catch {
    fputs("macip: \(safe(String(describing: error)))\n", stderr)
    exit(EXIT_FAILURE)
}
