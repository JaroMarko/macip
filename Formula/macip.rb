class Macip < Formula
  desc "Simple read-only IP address viewer for macOS"
  homepage "https://github.com/JaroMarko/macip"
  url "https://github.com/JaroMarko/macip/releases/download/v0.2.1/macip-macos-universal.tar.gz"
  version "0.2.1"
  sha256 "33fbdc0fdab2249c0d4ce51daef0b10a25be98aa83a848462d638527606564ef"
  license "MIT"

  depends_on :macos
  on_macos do
    depends_on macos: :tahoe
  end

  def install
    bin.install "macip"
    bin.install_symlink "macip" => "ip"
  end

  test do
    assert_match "macip 0.2.1", shell_output("#{bin}/macip --version")
    assert_match "127.0.0.1", shell_output("#{bin}/ip a show lo0")
  end
end
