class Macip < Formula
  desc "Simple read-only IP address viewer for macOS"
  homepage "https://github.com/JaroMarko/macip"
  url "https://github.com/JaroMarko/macip/releases/download/v0.1.2/macip-macos-universal.tar.gz"
  version "0.1.2"
  sha256 "d3270b75b74ea1a33c17a2b65778c282fffa2afdbb5a9ed95ab1940736252e2b"
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
    assert_match "macip 0.1.2", shell_output("#{bin}/macip --version")
    assert_match "127.0.0.1", shell_output("#{bin}/ip a show lo0")
  end
end
