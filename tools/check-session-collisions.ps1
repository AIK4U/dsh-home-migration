# check-session-collisions.ps1 -- FAIL-CLOSED gate: does this DSH home hold the same
# session id under two different project (bucket) directories?
#
# WHAT IT DECIDES (read this before you trust it)
#   PASS  (exit 0): every entry name under <home>\sessions\* is carried by exactly ONE bucket,
#                   or the home has no sessions directory yet (a true, harmless state).
#   FAIL  (exit 1): at least one entry name appears under MORE THAN ONE bucket. That state is
#                   fatal for the home: the host will refuse every workspace operation while
#                   it lasts, and it will NOT write a log saying so.
#   ERROR (exit 2): the state could not be read, the home does not exist, or no -DshHome was
#                   given. Unreadable state is reported as FAILURE, never as "clean" -- an
#                   empty result and an unreadable result must never look the same.
#
#   This desensitized copy writes <OLD_ROOT> / <NEW_ROOT> where the real paths stood; every
#   path arrives through argv, so nothing here is machine-specific.
#
# WHY THIS EXISTS (root cause proven 2026-10-15, after six migration rounds)
#   A DSH home is only usable when every stored session id is unique. Three links in
#   the core chain enforce that, and one duplicated id kills all three:
#
#   1. @deepseek-ai/dsh-session-persistence-jsonl/lib/index.js
#        :2878  listArtifacts(): if (ids.has(header.id)) throw new Error(
#                 'duplicate JSONL session id "<id>" appears in multiple project directories')
#        :2454  the public Service method list() iterates listArtifacts(), so list()
#               cannot succeed while a duplicate exists.
#   2. @deepseek-ai/dsh-workspace/lib/index.js
#        :314   WorkspaceRegistry  static inject = ["storageDomain", "sessionPersistence"]
#        :336   Service.init -> :729 listStoredHeaders() -> ctx.sessionPersistence.list()
#               The init throws, so the workspaceRegistry service NEVER activates.
#   3. @deepseek-ai/dsh-api-workspace-controller/lib/index.js
#        :657   WorkspaceController  static inject = ["typert", "workspaceRegistry"]
#               Its dependency is missing, so workspaceController never activates.
#
#   @deepseek-ai/dsh-api-gateway/lib/index.js:743 then answers every workspace call with
#       active Service "workspaceController" is unavailable
#   which is exactly the symptom "the desktop app cannot use workspaces". The host
#   writes NO startup-failure log for this, which is why it looked traceless.
#
#   A bucket name is an ENCODING OF THE SESSION'S cwd: every non-ASCII code unit becomes
#   ~XXXX, separators become "-", and the whole thing is wrapped in "--". So "an old-name
#   bucket and a new-name bucket side by side" is itself the fingerprint of a collision.
#
# WHY IT RECURS AFTER EVERY MIGRATION
#   The migration's incremental copy re-imports the OLD-named session buckets from the
#   still-live old root into a home whose buckets an earlier attempt already renamed,
#   so the same session exists twice. The resolver (resolve-bucket-collisions.mjs) must
#   run in the SAME stop-the-world window as the switch, and only then can the path fix
#   (fix-paths.mjs) merge the buckets. This gate is the assertion that step was reached.
#
#   Usage: run it BEFORE re-pointing anything, run it again after the fix, and run it
#   against BOTH homes during a migration (the live one must be clean, and comparing the
#   two tells you which side manufactured the duplicate).
#
# usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File check-session-collisions.ps1 -DshHome <path>
#   exit 0 = no duplicates (or no sessions directory at all)
#   exit 1 = duplicates found  -> the app must NOT be started on this home
#   exit 2 = the state could not be read (treated as failure, never as "clean")
#
# ASCII-only on purpose (HARD-RULES H6): PowerShell 5.1 reads a BOM-less .ps1 as ANSI,
# so any non-ASCII byte here would be read as mojibake. All paths arrive via argv.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$DshHome,
  [switch]$Quiet,
  [int]$ShowLimit = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SessionOwners {
  # Returns a hashtable: entry name -> list of bucket names that hold it.
  # Bounded: one pass over the bucket directories, one pass over each bucket.
  param([string]$SessionsRoot)
  $owners = @{}
  $buckets = $null
  try {
    $buckets = @(Get-ChildItem -LiteralPath $SessionsRoot -Force -Directory -ErrorAction Stop)
  } catch {
    throw ("cannot list session buckets under '" + $SessionsRoot + "': " + $_.Exception.Message)
  }
  foreach ($bucket in $buckets) {
    $entries = $null
    try {
      $entries = @(Get-ChildItem -LiteralPath $bucket.FullName -Force -ErrorAction Stop)
    } catch {
      throw ("cannot list bucket '" + $bucket.Name + "': " + $_.Exception.Message)
    }
    foreach ($entry in $entries) {
      if (-not $owners.ContainsKey($entry.Name)) {
        $owners[$entry.Name] = New-Object System.Collections.Generic.List[string]
      }
      [void]$owners[$entry.Name].Add($bucket.Name)
    }
  }
  return $owners
}

function Get-DuplicateSessionNames {
  # Every entry name carried by more than one bucket, in a stable order.
  param([hashtable]$Owners)
  $dups = New-Object System.Collections.Generic.List[string]
  foreach ($name in @($Owners.Keys | Sort-Object)) {
    if ($Owners[$name].Count -gt 1) { $dups.Add([string]$name) }
  }
  return $dups
}

function Write-Verdict {
  param([string]$Text, [string]$Color)
  if (-not $Quiet) { Write-Host $Text -ForegroundColor $Color }
}

if ([string]::IsNullOrWhiteSpace($DshHome)) {
  # Fail closed: a missing argument is an ERROR, not a pass.
  Write-Host 'DshHome is required' -ForegroundColor Red
  exit 2
}
if (-not (Test-Path -LiteralPath $DshHome)) {
  # Fail closed: an unreadable home must never be reported as clean.
  Write-Host ("home does not exist: " + $DshHome) -ForegroundColor Red
  exit 2
}
$sessionsRoot = Join-Path $DshHome 'sessions'
if (-not (Test-Path -LiteralPath $sessionsRoot)) {
  # A home with no sessions yet cannot collide -- that is a true, harmless state.
  Write-Verdict ("  [ok] no sessions directory yet: " + $sessionsRoot) 'DarkGray'
  exit 0
}

try {
  $owners = Get-SessionOwners -SessionsRoot $sessionsRoot
} catch {
  # Fail closed: unreadable bucket state is a FAILURE, never "clean".
  Write-Host ("  [error] cannot read session state: " + $_.Exception.Message) -ForegroundColor Red
  exit 2
}

# @() is REQUIRED: a function that returns an EMPTY collection unrolls to $null, and
# under Set-StrictMode -Version Latest $null.Count is a terminating error. Without the
# wrapper the clean case (0 duplicates) crashed instead of passing -- caught by running
# this gate against the clean old home, not by reading it.
$dups = @(Get-DuplicateSessionNames -Owners $owners)

Write-Verdict '' 'Gray'
Write-Verdict ("  home        : " + $DshHome) 'Gray'
Write-Verdict ("  bucket dirs : " + (@(Get-ChildItem -LiteralPath $sessionsRoot -Force -Directory).Count)) 'Gray'
Write-Verdict ("  entries     : " + $owners.Keys.Count) 'Gray'

if ($dups.Count -eq 0) {
  Write-Verdict '  duplicates  : 0  -- the workspace service chain can activate' 'Green'
  exit 0
}

Write-Verdict ("  duplicates  : " + $dups.Count + "  -- BLOCKING") 'Red'
$shown = 0
foreach ($name in $dups) {
  if ($shown -ge $ShowLimit) {
    Write-Verdict ("      ... and " + ($dups.Count - $ShowLimit) + " more") 'DarkGray'
    break
  }
  Write-Verdict ("      " + $name) 'Red'
  foreach ($bucket in $owners[$name]) { Write-Verdict ("          in " + $bucket) 'DarkGray' }
  $shown += 1
}
Write-Verdict '' 'Gray'
Write-Verdict '  This home CANNOT serve workspaces: the host will answer' 'Yellow'
Write-Verdict '      active Service "workspaceController" is unavailable' 'Yellow'
Write-Verdict '  Do NOT start the app on it. Resolve first, in this order:' 'Yellow'
Write-Verdict '      1. node resolve-bucket-collisions.mjs <home> <backupDir> --apply' 'Yellow'
Write-Verdict '      2. repoint-paths.ps1      (merge the buckets + rewrite the headers)' 'Yellow'
Write-Verdict '      3. this gate again       (must print duplicates: 0)' 'Yellow'
exit 1
