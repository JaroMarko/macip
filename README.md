# macip

A small, read-only IP address viewer for macOS 26 and newer. Written in Swift with no third-party dependencies.

```sh
macip -c a
macip a --all
macip a show en0
macip route
```

IPv4 addresses include both the prefix length and dotted subnet mask. IPv6 includes the prefix and scope when applicable. UP is an administrative interface state, not proof that the Internet works. Tunnel interfaces are not automatically identified as VPNs. `route` shows primary service routing information, not the complete routing table.

## Build

Install Xcode Command Line Tools, then:

```sh
swift build -c release
.build/release/macip -c a
```

To use familiar Linux spelling without replacing another executable, add this to your shell configuration:

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

Push a `v*` version tag to build a universal Apple Silicon/Intel binary in GitHub Actions. The release includes an archive and SHA-256 checksum. Homebrew installation instructions will be added with the first release formula.

MIT licensed.
