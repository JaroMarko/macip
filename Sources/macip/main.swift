import Darwin
import Foundation
import MacIPCore
import SystemConfiguration

private let version = "0.1.0"

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

private func addressText(_ address: NetworkAddress) -> String {
    let value = safe(address.address)
    if let length = address.prefixLength {
        let mask = address.family == "inet" ? address.netmask.map { "  mask " + safe($0) } ?? "" : ""
        let scope = address.address.hasPrefix("fe80:") ? "  link-local" : ""
        return "\(address.family) \(value)/\(length)\(mask)\(scope)"
    }
    if let mask = address.netmask, !mask.isEmpty { return "\(address.family) \(value) mask \(safe(mask))" }
    return "\(address.family) \(value)"
}

private func isHelper(_ name: String) -> Bool {
    ["awdl", "llw", "bridge", "ap"].contains { name.hasPrefix($0) }
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
        if interface.isLoopback { return false }
        if isHelper(interface.name) && interface.addresses.isEmpty { return false }
        return !interface.addresses.isEmpty || interface.isUp
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    for interface in visible {
        let state = interface.isUp ? "UP" : "DOWN"
        let stateColor = interface.isUp ? "32" : "90"
        let link = interface.isRunning ? " · RUNNING" : ""
        print("\(style.paint(safe(interface.name), code: "1"))  \(safe(interface.label))  \(style.paint(state, code: stateColor))\(link)")
        if interface.addresses.isEmpty {
            print("  (no IP address)")
        } else {
            for address in interface.addresses { print("  \(addressText(address))") }
        }
    }
    let hidden = interfaces.count - visible.count
    if options.interfaceName == nil && hidden > 0 { print("\(hidden) interfaces hidden; use --all to show them.") }
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
