class Zmx < Formula
  desc "Session persistence for terminal processes"
  homepage "https://github.com/neurosnap/zmx"
  version "0.0.3"
  license "MIT"

  on_macos do
    on_arm do
      url "https://zmx.sh/a/zmx-0.0.3-macos-aarch64.tar.gz"
      sha256 "07461346fffec650e87dafc18e8cc5132fdfbc61afa80b91cacdee0c2da70f8f"
    end
    on_intel do
      url "https://zmx.sh/a/zmx-0.0.3-macos-x86_64.tar.gz"
      sha256 "2325b2ed3b9dc57fe4d0d59571c3b13d2ebb8d189ba4138232bf413656816590"
    end
  end

  on_linux do
    on_arm do
      url "https://zmx.sh/a/zmx-0.0.3-linux-aarch64.tar.gz"
      sha256 "3a24faa8b127e49f8ce274974e03274755b58a9a491f7b04bbc8dca99ecb3dfb"
    end
    on_intel do
      url "https://zmx.sh/a/zmx-0.0.3-linux-x86_64.tar.gz"
      sha256 "d1dc35c310410ec4e2d1275555b8e01314faa2392084d24a367b0b4d72d0a456"
    end
  end

  def install
    bin.install "zmx"
  end

  test do
    assert_match "Usage: zmx", shell_output("#{bin}/zmx help")
  end
end
