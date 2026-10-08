class Macip < Formula
  desc "Simple read-only IP address viewer for macOS"
  homepage "https://github.com/JaroMarko/macip"
  url "https://github.com/JaroMarko/macip/releases/download/v0.1.1/macip-macos-universal.tar.gz"
  version "0.1.1"
  sha256 "948558e95899d013c1c06c0d130712faaf65b880f8a2a7d2e994c6d547449d09"
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
    assert_match "macip 0.1.1", shell_output("#{bin}/macip --version")
    assert_match "127.0.0.1", shell_output("#{bin}/ip a show lo0")
  end
end
