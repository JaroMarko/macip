class Macip < Formula
  desc "Simple read-only IP address viewer for macOS"
  homepage "https://github.com/JaroMarko/macip"
  url "https://github.com/JaroMarko/macip/releases/download/v0.2.4/macip-macos-universal.tar.gz"
  version "0.2.4"
  sha256 "211abbfd4ca19cb8f8a3188b9b758350799e827dc6932e07e322aa55c7294e8f"
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
    assert_match "macip 0.2.4", shell_output("#{bin}/macip --version")
    assert_match "127.0.0.1", shell_output("#{bin}/ip a show lo0")
  end
end
