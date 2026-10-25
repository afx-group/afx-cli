# Homebrew formula for the tap repository (afx-group/homebrew-afx, installs as `brew install afx-group/afx/afx-cli`).
# Template: 0.1.4 and 9da5576ff75d56929bf4bee3695c3c9afe7927af3855d474677f47e42b761a59 are substituted by export-public.mjs. Not published yet.
# bash and git come with macOS/Linux; Node.js 18+ is needed only for `afx init` and `afx fleet`.
class AfxCli < Formula
  desc "One front door to set up and govern AI coding agents across a team's machines"
  homepage "https://allforxproject.com/products/afx-cli"
  url "https://github.com/afx-group/afx-cli/releases/download/v0.1.4/afx-cli-0.1.4.tar.gz"
  sha256 "9da5576ff75d56929bf4bee3695c3c9afe7927af3855d474677f47e42b761a59"
  license "Apache-2.0"

  def install
    libexec.install Dir["*"]
    (bin/"afx").write <<~EOS
      #!/bin/sh
      AFX_GUARD_DIR="#{libexec}/scripts"
      export AFX_GUARD_DIR
      exec bash "#{libexec}/scripts/afx" "$@"
    EOS
  end

  test do
    assert_match "afx", shell_output("#{bin}/afx help")
  end
end
