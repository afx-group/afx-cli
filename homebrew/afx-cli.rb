# Homebrew formula for the tap repository (afx-group/homebrew-afx, installs as `brew install afx-group/afx/afx-cli`).
# Template: 0.1.2 and 5c8bdb1aba11d6ac21dff3698ad1e2b7c4c88268b9026e290e63d8a15866b745 are substituted by export-public.mjs. Not published yet.
# bash and git come with macOS/Linux; Node.js 18+ is needed only for `afx init` and `afx fleet`.
class AfxCli < Formula
  desc "One front door to set up and govern AI coding agents across a team's machines"
  homepage "https://allforxproject.com/products/afx-cli"
  url "https://github.com/afx-group/afx-cli/releases/download/v0.1.2/afx-cli-0.1.2.tar.gz"
  sha256 "5c8bdb1aba11d6ac21dff3698ad1e2b7c4c88268b9026e290e63d8a15866b745"
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
