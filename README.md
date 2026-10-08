# macip

A small, read-only IP address viewer for macOS 26 and newer. Written in Swift with no third-party dependencies.

## Install with Homebrew

```sh
brew tap jaromarko/macip https://github.com/JaroMarko/macip
brew install jaromarko/macip/macip
ip -c a
```

Installs a prebuilt universal binary for Apple Silicon and Intel. No Swift compiler is needed to use it. Both `macip` and `ip` are installed. If another package already provides `ip`, Homebrew reports the link conflict; existing executables are not overwritten automatically.

```sh
brew update
brew upgrade macip
```

## Usage

```sh
macip -c a
macip a --all
macip a show en0
macip route
```

IPv4 addresses include both the prefix length and dotted subnet mask. IPv6 includes the prefix and scope when applicable. The default view keeps Wi-Fi (including disconnected Wi-Fi), connected links even before they get an IP, interfaces with IPv4 or non-link-local IPv6, and the primary IPv4/IPv6 interfaces. Unused ports, internal Apple interfaces and link-local-only tunnels are hidden. Unknown types are retained conservatively. `--all` shows everything; `a show NAME` always shows the requested interface.

`UP` is an administrative interface state, not proof that the Internet works. `NO LINK` uses the system link state when available, and `NO IP` means no address has been assigned. Tunnel interfaces are not automatically identified as VPNs. `route` shows primary service routing information, not the complete routing table.

## Build

Install Xcode Command Line Tools, then:

```sh
swift build -c release
.build/release/macip -c a
```

For a source build, you can use familiar Linux spelling with a shell alias:

```sh
alias ip=macip
```

The tool only reads local network information. It does not change settings, request root privileges, send network probes, collect telemetry, or store addresses. Color is opt-in with `-c`, disabled for pipes, `NO_COLOR`, and dumb terminals.

## Verify

```sh
swift build --product macip
swift run MacIPChecks
bash scripts/check-cli.sh .build/debug/macip
```

## Release

Push a `v*` version tag to build a universal Apple Silicon/Intel binary in GitHub Actions. The release includes an archive and SHA-256 checksum. Update the version, URL, SHA-256 and version assertion in `Formula/macip.rb` after each release, then push the formula update.

MIT licensed.
