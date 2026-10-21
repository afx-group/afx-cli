<#
.SYNOPSIS
  Remove a git worktree on Windows, with the A-XPLAT-1 fallback sequence for
  pnpm-populated node_modules that `git worktree remove` can't delete.

.DESCRIPTION
  This one IS a native PowerShell implementation on purpose, unlike the other
  scripts in this folder: the failure it works around
  (`error: failed to delete '<path>': Result too large`) is Windows-specific
  — the Windows deletion API choking on pnpm's deeply-nested
  `.pnpm/<pkg>@<version>/node_modules/...` hardlink structure — so there is no
  portable bash script to wrap; this problem simply does not exist on
  macOS/Linux. See lessons-inbox/cross-platform.md A-XPLAT-1 for the incident
  this codifies (2026-09-27: a worktree survived
  `git worktree remove --force`, `rm -rf`, a robocopy-mirror-empty trick, and
  a long-path `rd /s /q`).

  Sequence:
    1. `git worktree remove --force` (fast path, works most of the time).
    2. On "Result too large": VERIFY, then move the folder to the Recycle Bin.
       Verify = every file outside node_modules/target/dist is byte-identical
       to the same path on origin/main, or is gitignored generated output.
       If anything else is there (someone's uncommitted or unmerged work) the
       script REFUSES (exit 3) and lists it: nothing is deleted. The Recycle
       Bin (not a permanent delete) uses the shell API, which does not hit the
       deep pnpm path limit and keeps the folder recoverable. Then
       `git worktree prune` / `git worktree remove` clear git's metadata.
    3. If a specific file then fails with "The file or directory is corrupted
       and unreadable" (not a permission/long-path message): STOP. This is a
       distinct, louder failure — real filesystem corruption, not a cleanup
       nuisance — and the script refuses to keep forcing it. Escalate to a
       disk check (chkdsk) before touching that area again.

.EXAMPLE
  .\afx-worktree-remove.ps1 -RepoPath C:\Users\you\Projects\...\my-app -WorktreePath C:\Users\you\Projects\...\my-app\.claude\worktrees\agent-x
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$RepoPath,
  [Parameter(Mandatory)][string]$WorktreePath,
  # The commit(s) the worktree's branch ended on, when you know them (the second parent of the PR's merge commit is the pushed tip).
  # origin/main keeps moving, so a file that was identical to main when the branch merged can differ from main NOW. With -TipCommit a file
  # also counts as safe when it is byte-identical to that commit, but only if the commit is an ancestor of origin/main (merged).
  [string[]]$TipCommit = @()
)

function Invoke-Git {
  param([string[]]$GitArgs)
  $out = & git -C $RepoPath @GitArgs 2>&1
  return @{ Output = ($out -join "`n"); Code = $LASTEXITCODE }
}

Write-Host "Removing worktree: $WorktreePath"
$r1 = Invoke-Git @('worktree', 'remove', '--force', $WorktreePath)
if ($r1.Code -eq 0) { Write-Host "OK: removed cleanly via git worktree remove --force"; exit 0 }

# A first attempt that died half way ("Result too large") leaves the worktree deregistered but its folder on disk; the next
# attempt then says "is not a working tree". Same situation, same safe path.
$orphan = ($r1.Output -match 'Result too large') -or (($r1.Output -match 'is not a working tree') -and (Test-Path -LiteralPath $WorktreePath))
if ($orphan) {
  Write-Warning "git's own delete choked on a long/hardlinked pnpm path (Result too large) — verifying the folder against origin/main, then moving it to the Recycle Bin."
  & git -C $RepoPath fetch origin --quiet 2>&1 | Out-Null
  $root = (Resolve-Path -LiteralPath $WorktreePath).Path.TrimEnd('\')
  # Walk the tree and never descend into node_modules/target/dist (they are not content and a pnpm node_modules has hundreds of
  # thousands of hard-linked files), and do not follow reparse points.
  $skip = @('node_modules', 'target', 'dist')
  $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
  $stack = New-Object 'System.Collections.Generic.Stack[string]'
  $stack.Push($root)
  while ($stack.Count -gt 0) {
    $dir = $stack.Pop()
    try {
      foreach ($f in [System.IO.Directory]::EnumerateFiles($dir)) { $list.Add([System.IO.FileInfo]::new($f)) }
      foreach ($sub in [System.IO.Directory]::EnumerateDirectories($dir)) {
        if ($skip -contains [System.IO.Path]::GetFileName($sub)) { continue }
        if ([System.IO.File]::GetAttributes($sub) -band [System.IO.FileAttributes]::ReparsePoint) { continue }
        $stack.Push($sub)
      }
    } catch { }
  }
  $files = @($list)

  # origin/main, plus every -TipCommit that is really merged into it: a file is safe if it is byte-identical to the content at ANY of them.
  # origin/main keeps moving, so a file that was identical to main when the branch merged can differ from main NOW.
  # `powershell -File ... -TipCommit a,b` arrives as ONE string "a,b": split it.
  $TipCommit = @($TipCommit | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  # No tip given: derive it. A worktree folder is <topic>-<date> on branch wip/<topic>-<date>, and origin/main holds the merge commit of that
  # branch's PR ("Merge pull request #N from <org>/wip/<name>"); its second parent is the pushed tip and its first parent is main as it
  # stood. Those are the commits a leftover folder's files match (origin/main itself has moved on since).
  if ($TipCommit.Count -eq 0) {
    $name = Split-Path -Leaf $WorktreePath
    foreach ($m in @(& git -C $RepoPath log origin/main --merges --format=%H -n 5 --fixed-strings --grep="wip/$name" 2>$null)) {
      foreach ($suffix in '^2', '^1') {
        $c = & git -C $RepoPath rev-parse -q --verify "$m$suffix" 2>$null
        if ($c) { $TipCommit += $c }
      }
    }
    if ($TipCommit.Count -gt 0) { Write-Host "No -TipCommit given: derived $($TipCommit.Count) commit(s) from the merged PR of wip/$name" }
  }
  $tips = @()
  foreach ($t in @($TipCommit | Where-Object { $_ })) {
    & git -C $RepoPath merge-base --is-ancestor $t origin/main 2>$null
    if ($LASTEXITCODE -eq 0) { $tips += $t } else { Write-Warning "-TipCommit $t is not an ancestor of origin/main: ignoring it" }
  }
  function Read-GitTree([string]$Rev) {
    $m = @{}
    $out = (& git -C $RepoPath ls-tree -r -z $Rev) -join ''
    foreach ($e in ($out -split "`0")) {
      if (-not $e) { continue }
      $tab = $e.IndexOf("`t")
      if ($tab -lt 0) { continue }
      $m[$e.Substring($tab + 1)] = $e.Substring(0, $tab).Split(' ')[2]
    }
    return ,$m
  }
  $trees = @()
  foreach ($rev in (@('origin/main') + $tips)) { $trees += ,(Read-GitTree $rev) }

  # Two git processes hash every file at once (raw bytes, and git-normalized: plain `hash-object` applies .gitattributes/autocrlf
  # filters and disagreed with the blob for byte-identical files on 2026-10-20). A match on either counts.
  # Paths go on the command line in chunks (stdin would get a byte-order mark from Windows PowerShell 5.1, and one command line is capped).
  function Get-GitHashes([string[]]$All, [string[]]$GitArgs) {
    $res = New-Object System.Collections.Generic.List[string]
    for ($o = 0; $o -lt $All.Count; $o += 80) {
      $chunk = $All[$o..([Math]::Min($o + 79, $All.Count - 1))]
      foreach ($h in (& git -C $RepoPath hash-object @GitArgs -- @chunk)) { $res.Add([string]$h) }
    }
    return ,@($res)
  }
  $paths = @($files | ForEach-Object { $_.FullName })
  $rawH = Get-GitHashes $paths @('--no-filters')
  $fltH = Get-GitHashes $paths @()
  if ($rawH.Count -ne $paths.Count -or $fltH.Count -ne $paths.Count) {
    Write-Error "could not hash every file ($($rawH.Count)/$($fltH.Count) of $($paths.Count)); nothing was deleted"
    exit 1
  }
  # A Git LFS file is a tiny pointer in the tree ("oid sha256:<hex>") and the real bytes in the working folder, so its git hash can never match:
  # accept it when the file's SHA-256 equals the oid in the pointer at origin/main or a tip.
  function Test-LfsMatch([string]$Rel, [string]$Full) {
    foreach ($tr in $trees) {
      $b = $tr[$Rel]
      if (-not $b) { continue }
      $size = & git -C $RepoPath cat-file -s $b 2>$null
      if ($LASTEXITCODE -ne 0 -or [int64]$size -gt 300) { continue }
      $text = (& git -C $RepoPath cat-file -p $b 2>$null) -join "`n"
      if ($text -match 'git-lfs\.github\.com/spec' -and $text -match 'oid sha256:([0-9a-f]{64})') {
        if ((Get-FileHash -LiteralPath $Full -Algorithm SHA256).Hash.ToLowerInvariant() -eq $Matches[1]) { return $true }
      }
    }
    return $false
  }
  $unknown = @()
  for ($i = 0; $i -lt $files.Count; $i++) {
    $rel = $files[$i].FullName.Substring($root.Length + 1) -replace '\\', '/'
    $ok = $false
    foreach ($tr in $trees) {
      $b = $tr[$rel]
      if ($b -and ($b -eq $rawH[$i] -or $b -eq $fltH[$i])) { $ok = $true; break }
    }
    if ($ok) { continue }
    if ($rel -eq '.git') { continue }   # the worktree's own pointer file: not content
    if ($rel -match '/src-tauri/gen/') { continue }
    if (Test-LfsMatch $rel $files[$i].FullName) { continue }
    $unknown += $rel
  }
  # what is left must be gitignored generated output
  $bad = @()
  if ($unknown.Count -gt 0) {
    $ignored = @()
    for ($o = 0; $o -lt $unknown.Count; $o += 80) {
      $chunk = $unknown[$o..([Math]::Min($o + 79, $unknown.Count - 1))]
      $ignored += @(& git -C $RepoPath check-ignore --no-index -- @chunk 2>$null)
    }
    foreach ($u in $unknown) { if ($ignored -notcontains $u) { $bad += $u } }
  }
  if ($bad.Count -gt 0) {
    Write-Error "REFUSED: $($bad.Count) file(s) in $root are not on origin/main and not gitignored (uncommitted or unmerged work, which is not ours to discard). First: $($bad | Select-Object -First 5 | ForEach-Object { $_ }). Nothing was deleted. Commit and push them, or ask the owner."
    exit 3
  }
  try {
    Add-Type -AssemblyName Microsoft.VisualBasic
    [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($root, 'OnlyErrorDialogs', 'SendToRecycleBin')
  } catch {
    if ($_.Exception.Message -match 'corrupted and unreadable') {
      Write-Error "STOP: '$($_.TargetObject)' is reported corrupted and unreadable. This is real filesystem corruption, not a cleanup nuisance — run chkdsk on this volume before continuing any cleanup here. Not retrying further."
      exit 2
    }
    Write-Error "Moving the folder to the Recycle Bin failed: $($_.Exception.Message)"
    exit 1
  }
  Write-Host "Moved to the Recycle Bin after checking $($files.Count) file(s) against origin/main."
  git -C $RepoPath worktree prune 2>&1 | Out-Null
  $r2 = Invoke-Git @('worktree', 'remove', '--force', $WorktreePath)
  if ($r2.Code -eq 0 -or -not (Test-Path -LiteralPath $WorktreePath)) {
    Write-Host "OK: verified against origin/main, moved to the Recycle Bin, git records pruned"
    exit 0
  }
  Write-Error "Still failed after the fallback: $($r2.Output)"
  exit 1
}

if ($r1.Output -match 'corrupted and unreadable') {
  Write-Error "STOP: git itself reports a corrupted/unreadable file under $WorktreePath. This is real filesystem corruption — run chkdsk before continuing. Not retrying further."
  exit 2
}

Write-Error "git worktree remove failed for an unrecognized reason: $($r1.Output)"
exit 1
