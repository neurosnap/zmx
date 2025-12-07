class Zmx < Formula
  desc "Session persistence for terminal processes"
  homepage "https://github.com/neurosnap/zmx"
  version "0.0.2"
  license "MIT"

  on_macos do
    on_arm do
      url "https://zmx.sh/a/zmx-0.0.2-macos-aarch64.tar.gz"
      sha256 "694d954f3831fa81f99a43fe53b8faa321713c4ce76b4f09992ea930486899e1"
    end

    on_intel do
      url "https://zmx.sh/a/zmx-0.0.2-macos-x86_64.tar.gz"
      sha256 "15d00c262b7e501aa73f27ca27362cac515f4542d06a925ad0aa4b5f3a7a7f3a"
    end
  end

  on_linux do
    on_arm do
      url "https://zmx.sh/a/zmx-0.0.2-linux-aarch64.tar.gz"
      sha256 "748e561bf67498580c9234cc4c723d36757de2950650da9746a2db29fe50f418"
    end

    on_intel do
      url "https://zmx.sh/a/zmx-0.0.2-linux-x86_64.tar.gz"
      sha256 "9cede1e4b017256f99821fc2a55f97e97abf574efc3bbf360add76183462058a"
    end
  end

  def install
    bin.install "zmx"
  end

  test do
    assert_match "Usage: zmx", shell_output("#{bin}/zmx help")
  end
end
