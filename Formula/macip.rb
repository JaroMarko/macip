class Macip < Formula
  desc "Simple read-only IP address viewer for macOS"
  homepage "https://github.com/JaroMarko/macip"
  url "https://github.com/JaroMarko/macip/releases/download/v1.0.0/macip-macos-universal.tar.gz"
  version "1.0.0"
  sha256 "439a74c3c007ffbff5eab84134dc3e239575c39fdf2e1879dc1f4ad29598a09e"
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
    assert_match "macip 1.0.0", shell_output("#{bin}/macip --version")
    assert_match "127.0.0.1", shell_output("#{bin}/ip a show lo0")
  end
end
