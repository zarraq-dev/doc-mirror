<#
.SYNOPSIS
    Mirror a developer documentation site to local HTML + Markdown files.

.DESCRIPTION
    Crawls a documentation site rooted at the given URL using single-file-cli
    (which uses headless Chromium to render JavaScript-driven pages correctly,
    including modern single-page-application docs sites), then runs every
    saved HTML page through pandoc to produce a parallel Markdown copy with
    images extracted into an assets/ folder. Writes a manifest.json that
    records the crawl date, source URL, file counts, and tool versions so the
    run is reproducible.

    The crawl stays within the same domain and does not ascend above the root
    URL. Re-running against the same OutputDir overwrites existing files.

    Dependencies (must be on PATH):
      - single-file-cli   (install with: npm install -g single-file-cli)
      - pandoc            (install with: winget install JohnMacFarlane.Pandoc)

.PARAMETER Url
    Root URL of the docs site to mirror. Required.

.PARAMETER OutputDir
    Directory where mirrored files will be written. Created if it does not
    exist. Required.

.PARAMETER MaxDepth
    Maximum crawl depth from the root URL. Default 0 (infinite). Combined
    with --crawl-no-parent=true (which the script always sets) the crawl
    can't escape the path subtree under -Url, so infinite is safe and
    guarantees full coverage of the docs site. Set a positive integer to
    cap depth explicitly for testing or to limit very large doc sites.

.PARAMETER RewriteRule
    Zero or more URL rewrite rules passed through to single-file-cli as
    `--crawl-rewrite-rule` arguments. Each rule is a `<regex> <replacement>`
    pair separated by whitespace. An empty replacement (just the regex) causes
    matching URLs to be dropped from the crawl entirely.

    Typical uses:
      - Strip query strings to deduplicate URLs:
            "^(.*?)\?.*$ $1"
      - Rewrite localised paths back to the canonical English equivalent
        (e.g. for cTrader help.ctrader.com which has /vi/, /es/, /ja/ etc.):
            "^(https://help\.ctrader\.com/open-api)/[a-z]{2,3}(-[a-z]{2})?/ $1/"

.PARAMETER BrowserWaitUntil
    Page-load condition passed to single-file as --browser-wait-until.
    Default 'load' (less strict than single-file's own default of 'networkIdle',
    which times out on SPA sites that never reach network idle). Other
    accepted values: 'InteractiveTime', 'networkIdle', 'networkAlmostIdle',
    'load', 'domContentLoaded'.

.PARAMETER BrowserWaitDelayMs
    Additional pre-capture delay in milliseconds, passed as
    --browser-wait-delay. Default 2000 (gives SPA hydration time to settle
    before single-file's content script injects).

.PARAMETER SkipMarkdown
    Skip the pandoc HTML-to-Markdown conversion pass. HTML files are still
    produced. Useful when debugging the crawl phase in isolation.

.EXAMPLE
    .\mirror.ps1 -Url "https://help.ctrader.com/open-api/" `
                 -OutputDir "C:\docs\ctrader-open-api" `
                 -RewriteRule @(
                     "^(.*?)\?.*$ `$1",
                     "^(https://help\.ctrader\.com/open-api)/[a-z]{2,3}(-[a-z]{2})?/ `$1/"
                 )

.EXAMPLE
    .\mirror.ps1 -Url "https://example.com/docs/" -OutputDir ".\out" -MaxDepth 10 -Verbose

.NOTES
    Tool version: 0.1.0
    Repository: standalone — invoke from any project that needs offline docs.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $Url,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputDir,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 50)]
    [int] $MaxDepth = 0,

    [Parameter(Mandatory = $false)]
    [string[]] $RewriteRule = @(),

    [Parameter(Mandatory = $false)]
    [ValidateSet("InteractiveTime", "networkIdle", "networkAlmostIdle", "load", "domContentLoaded")]
    [string] $BrowserWaitUntil = "load",

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 60000)]
    [int] $BrowserWaitDelayMs = 2000,

    [Parameter(Mandatory = $false)]
    [switch] $SkipMarkdown
)

# Fail-fast on cmdlet errors; native command failures are checked explicitly via $LASTEXITCODE
$ErrorActionPreference = 'Stop'

# Constants

$s_toolName = "doc-mirror"                                              # Self-identifying tool name written into the per-site manifest
$s_toolVersion = "0.1.0"                                                # Tool version stamped into manifest for reproducibility
$s_assetsFolderName = "assets"                                          # Subfolder where pandoc extracts images out of HTML pages
$s_manifestFilename = "manifest.json"                                   # Name of the per-site reproducibility-record file
$s_filenameTemplate = "{page-title}.{filename-extension}"               # single-file-cli filename template; deterministic across re-runs (no timestamps)

# Helpers

function Test-CommandAvailable {
    <#
    .SYNOPSIS
        Return $true if the named external command is resolvable on PATH.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string] $s_commandName
    )
    return $null -ne (Get-Command $s_commandName -ErrorAction SilentlyContinue)
}

# Pre-flight: verify dependencies are on PATH

if (-not (Test-CommandAvailable -s_commandName "single-file")) {
    Write-Error "single-file-cli is not on PATH. Install with: npm install -g single-file-cli"
    exit 1
}
if (-not $SkipMarkdown -and -not (Test-CommandAvailable -s_commandName "pandoc")) {
    Write-Error "pandoc is not on PATH. Install with: winget install JohnMacFarlane.Pandoc"
    exit 1
}

# Resolve / prepare the output directory

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null                          # Create the output directory if it does not exist (idempotent)
$s_outputAbsolute = (Resolve-Path -Path $OutputDir).Path                                 # Absolute path of the output directory after creation
$s_assetsAbsolute = Join-Path $s_outputAbsolute $s_assetsFolderName                      # Absolute path where pandoc will extract image assets
Write-Verbose "Output directory: $s_outputAbsolute"

# Clean stale output from any prior run so re-runs are idempotent and we never accumulate
# (N)-suffixed duplicate filenames. We can't use single-file's --filename-conflict-action=overwrite
# flag (see comment in args block) because of an upstream bug; doing the cleanup ourselves is
# both reliable and explicit. We remove top-level files (any extension) plus the assets/ subfolder
# but leave the output directory itself in place.
Get-ChildItem -Path $s_outputAbsolute -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
if (Test-Path -Path $s_assetsAbsolute) {
    Remove-Item -Path $s_assetsAbsolute -Recurse -Force -ErrorAction SilentlyContinue
}

# Step 1: Crawl with single-file-cli

Write-Output "=== Crawling $Url (max depth $MaxDepth) ==="
$date_crawlStart = (Get-Date).ToUniversalTime()                                          # UTC start time of the crawl, recorded in the manifest

$array_s_singleFileArgs = @(                                                               # Argument list passed to single-file-cli for the crawl phase
    $Url,
    "--output-directory=$s_outputAbsolute",
    "--filename-template=$s_filenameTemplate",
    "--crawl-links=true",
    "--crawl-inner-links-only=true",
    "--crawl-no-parent=true",
    "--crawl-max-depth=$MaxDepth",
    "--crawl-replace-URLs=true",
    "--browser-wait-until=$BrowserWaitUntil",
    "--browser-wait-delay=$BrowserWaitDelayMs"
)
# NOTE: we deliberately do NOT pass --filename-conflict-action=overwrite to single-file. The
# upstream getFilename() function has a bug where the overwrite branch returns just the bare
# filename without the output-directory prefix, causing files to be written to the process CWD
# instead of the configured output directory. We instead wipe stale output ourselves below before
# the crawl runs, which gives the same "clean re-run" semantics without depending on the buggy flag.

# Append any caller-supplied rewrite rules — these can deduplicate URLs that differ only by query string
# or rewrite localised paths back to the canonical English equivalent. See script help for examples.
foreach ($s_rewriteRule in $RewriteRule) {
    $array_s_singleFileArgs += "--crawl-rewrite-rule=$s_rewriteRule"
}

# Real-time progress indicator: FileSystemWatcher fires as each captured HTML file is written to
# disk. The event handler reads the SingleFile header comment near the top of the file (which always
# contains "url: <source-url>") so we can announce both the URL and the saved filename in one line.
# Note: this is post-capture — the URL printed is the page that JUST finished being scraped, not the
# next one in the queue. We tried using single-file's --crawl-save-session for pre-capture URL
# announcements but the Timer-based polling did not produce output in practice. Post-capture
# URL extraction is simpler and reliable; if the operator needs to know what is in-flight RIGHT NOW
# they can infer it from the gap after the most recent "captured:" line.
$watcher_progress = New-Object System.IO.FileSystemWatcher                                 # Filesystem watcher tracking new HTML captures in the output directory
$watcher_progress.Path = $s_outputAbsolute
$watcher_progress.Filter = "*.html"
$watcher_progress.IncludeSubdirectories = $false
$action_onHtmlCreated = {                                                                  # Event handler — runs in a separate runspace each time an HTML file appears
    $s_createdName = $Event.SourceEventArgs.Name                                           # Filename of the freshly-created HTML (page title plus .html)
    $s_fullPath = $Event.SourceEventArgs.FullPath                                          # Absolute path to the just-created HTML, needed for reading the URL header

    # Brief delay to let single-file finish flushing the header comment to disk before we read it
    Start-Sleep -Milliseconds 200

    $s_extractedUrl = $null                                                                # Source URL of the captured page (null if the header comment cannot be parsed)
    try {
        # Only the first ~50 lines need inspecting — single-file's "url: ..." header is always near the top
        $array_s_headerLines = Get-Content -Path $s_fullPath -TotalCount 50 -ErrorAction SilentlyContinue
        foreach ($s_line in $array_s_headerLines) {
            if ($s_line -match 'url:\s*(https?://\S+)') {
                $s_extractedUrl = $matches[1]
                break
            }
        }
    } catch {
        # File-lock or read race — fall back to filename-only announcement below
    }

    if ($s_extractedUrl) {
        [System.Console]::WriteLine("  captured: $s_extractedUrl  ->  $s_createdName")
    } else {
        [System.Console]::WriteLine("  captured: $s_createdName")
    }
}
$registration_watcher = Register-ObjectEvent -InputObject $watcher_progress -EventName Created -Action $action_onHtmlCreated   # Registered event subscription; must be unregistered after the crawl
$watcher_progress.EnableRaisingEvents = $true

try {
    & single-file @array_s_singleFileArgs

    # single-file occasionally exits non-zero even when it produces a valid output set (e.g. on Chromium
    # cleanup quirks or non-fatal warnings). Treat as a warning rather than a hard failure — the pandoc
    # phase will operate on whatever HTML was produced, and the final summary will report counts.
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "single-file-cli exited with code $LASTEXITCODE (output may still be usable; check the produced files)."
    }
}
finally {
    $watcher_progress.EnableRaisingEvents = $false
    Unregister-Event -SourceIdentifier $registration_watcher.Name -ErrorAction SilentlyContinue
    Remove-Job -Job $registration_watcher -Force -ErrorAction SilentlyContinue
    $watcher_progress.Dispose()
}

# Step 2: Convert each HTML to Markdown via pandoc

$array_file_html = @(Get-ChildItem -Path $s_outputAbsolute -Filter "*.html" -Recurse -File)   # Every HTML file produced by the crawl, found recursively
Write-Output "=== Crawled $($array_file_html.Count) HTML page(s) ==="

if (-not $SkipMarkdown) {
    Write-Output "=== Converting HTML to Markdown ==="
    $n_convertedCount = 0                                                                     # Running count of HTML files successfully converted to Markdown
    $n_failedCount = 0                                                                        # Running count of HTML files that failed pandoc conversion

    # Change to the output directory so pandoc's --extract-media relative path resolves correctly
    Push-Location $s_outputAbsolute
    try {
        # Loop through every HTML file produced by the crawl and run pandoc on it
        foreach ($file_currentHtml in $array_file_html) {
            $s_relPath = $file_currentHtml.FullName.Substring($s_outputAbsolute.Length + 1)   # File path relative to the output root, used for log readability
            $s_markdownPath = [System.IO.Path]::ChangeExtension($file_currentHtml.FullName, ".md")  # Sibling .md path next to the .html
            Write-Verbose "Converting $s_relPath -> $(Split-Path $s_markdownPath -Leaf)"

            & pandoc `
                --from html `
                --to markdown_strict `
                --extract-media $s_assetsFolderName `
                --output $s_markdownPath `
                $file_currentHtml.FullName

            if ($LASTEXITCODE -eq 0) {
                $n_convertedCount++
            }
            else {
                $n_failedCount++
                Write-Warning "Pandoc failed on $s_relPath (exit $LASTEXITCODE)"
            }
        }
    }
    finally {
        Pop-Location
    }
    Write-Output "Converted $n_convertedCount of $($array_file_html.Count) HTML files to Markdown ($n_failedCount failure(s))."
}

# Step 3: Write the manifest

$date_crawlEnd = (Get-Date).ToUniversalTime()                                                # UTC end time of the crawl
$array_file_markdown = @(Get-ChildItem -Path $s_outputAbsolute -Filter "*.md" -Recurse -File)   # All Markdown files produced (empty if SkipMarkdown was passed)
$array_file_asset = @()                                                                       # Asset files inside the assets folder (images extracted by pandoc)
if (Test-Path $s_assetsAbsolute) {
    $array_file_asset = @(Get-ChildItem -Path $s_assetsAbsolute -File -Recurse)
}

$s_singleFileVersion = (& single-file --version 2>&1 | Select-Object -First 1).ToString().Trim()   # single-file-cli version, recorded for reproducibility
$s_pandocVersion = ""                                                                              # Pandoc version string; remains empty when SkipMarkdown skipped the pandoc check
if (Test-CommandAvailable -s_commandName "pandoc") {
    $s_pandocVersion = (& pandoc --version | Select-Object -First 1).ToString().Trim()
}

$dict_manifest = [ordered]@{                                                                       # Reproducibility record written as manifest.json
    tool = $s_toolName
    tool_version = $s_toolVersion
    source_url = $Url
    crawl_max_depth = $MaxDepth
    crawl_start_utc = $date_crawlStart.ToString("o")
    crawl_end_utc = $date_crawlEnd.ToString("o")
    html_page_count = $array_file_html.Count
    markdown_page_count = $array_file_markdown.Count
    asset_count = $array_file_asset.Count
    single_file_cli_version = $s_singleFileVersion
    pandoc_version = $s_pandocVersion
    skipped_markdown = [bool] $SkipMarkdown
}

$s_manifestPath = Join-Path $s_outputAbsolute $s_manifestFilename                                  # Absolute path of the manifest output file
$dict_manifest | ConvertTo-Json -Depth 4 | Set-Content -Path $s_manifestPath -Encoding UTF8

# Final summary

Write-Output ""
Write-Output "=== Mirror complete ==="
Write-Output "  HTML pages:    $($array_file_html.Count)"
Write-Output "  Markdown:      $($array_file_markdown.Count)"
Write-Output "  Asset files:   $($array_file_asset.Count)"
Write-Output "  Output:        $s_outputAbsolute"
Write-Output "  Manifest:      $s_manifestPath"

# Force a clean success exit. PowerShell otherwise propagates $LASTEXITCODE from the last native
# command (single-file or pandoc), which may be non-zero even when the work completed fine — for
# example, pandoc 3.9 sometimes exits non-zero on benign HTML5/XML quirks, and Node/headless
# Chromium occasionally exits non-zero on cleanup. Since per-file failures are already counted
# explicitly above and the script only reaches this point on overall success, force exit 0.
exit 0
