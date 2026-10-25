# Homebrew formula for the tap repository (afx-group/homebrew-afx, installs as `brew install afx-group/afx/afx-cli`).
# Template: 0.1.3 and 42221356591cb3b7da4335b90849985ba34674812c5c37ca5b4fcde7e4ffef88 are substituted by export-public.mjs. Not published yet.
# bash and git come with macOS/Linux; Node.js 18+ is needed only for `afx init` and `afx fleet`.
class AfxCli < Formula
  desc "One front door to set up and govern AI coding agents across a team's machines"
  homepage "https://allforxproject.com/products/afx-cli"
  url "https://github.com/afx-group/afx-cli/releases/download/v0.1.3/afx-cli-0.1.3.tar.gz"
  sha256 "42221356591cb3b7da4335b90849985ba34674812c5c37ca5b4fcde7e4ffef88"
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
