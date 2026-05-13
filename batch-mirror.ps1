<#
.SYNOPSIS
    Mirror multiple documentation sites defined in a configuration file.

.DESCRIPTION
    Reads a PowerShell data file (.psd1) listing one or more site configurations
    and invokes the single-site mirror.ps1 tool for each. Sites are processed
    sequentially. A failure on one site is logged but does not stop subsequent
    sites from being processed. A summary is printed at the end.

    Each site config supports the following keys:
      - Name         (mandatory): folder name used for this site's output
      - Url          (mandatory): starting URL for the crawl
      - RewriteRule  (optional):  array of regex rewrite rules
                                  (format: '<regex> <replacement>' per entry)

    See sites.example.psd1 for the expected file format with documentation
    of each field.

.PARAMETER SitesConfig
    Path to a .psd1 data file containing an array of site hashtables.

.PARAMETER OutputRoot
    Root directory where per-site outputs are written. Each site's mirrored
    content goes into <OutputRoot>/<site.Name>/.

.PARAMETER OnlySite
    Optional. Mirror only the site whose Name property matches this value.
    Comparison is case-sensitive. Useful for re-running a single site after
    a config change without re-mirroring the others.

.PARAMETER MaxDepth
    Maximum crawl depth per site, passed through to mirror.ps1. Default 0
    (infinite, bounded by --crawl-no-parent — see mirror.ps1 documentation).
    A positive integer caps depth explicitly for testing or very large sites.

.EXAMPLE
    .\batch-mirror.ps1 -SitesConfig .\sites.psd1 -OutputRoot C:\mirrors

.EXAMPLE
    .\batch-mirror.ps1 -SitesConfig .\sites.psd1 -OutputRoot .\out -OnlySite "example-site-one"

.NOTES
    Requires mirror.ps1 to live in the same directory as this script.
    Dependencies: PowerShell 7+, mirror.ps1 plus its own dependencies
    (Node.js, single-file-cli, pandoc).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string] $SitesConfig,

    [Parameter(Mandatory = $true, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [string] $OutputRoot,

    [Parameter(Mandatory = $false)]
    [string] $OnlySite,

    [Parameter(Mandatory = $false)]
    [ValidateRange(0, 50)]
    [int] $MaxDepth = 0
)

# Fail-fast on cmdlet errors. The per-site mirror.ps1 invocation is wrapped in try/catch below
# so a single site's failure cannot kill the whole batch.
$ErrorActionPreference = 'Stop'

# Locate the single-site mirror.ps1 alongside this script

$s_thisScriptDir = $PSScriptRoot                                                       # Directory of this batch script (used to locate the companion mirror.ps1)
$s_mirrorScript = Join-Path $s_thisScriptDir "mirror.ps1"                              # Expected location of the per-site mirror tool
if (-not (Test-Path -Path $s_mirrorScript)) {
    Write-Error "mirror.ps1 was not found next to batch-mirror.ps1 (looked at $s_mirrorScript)."
    exit 1
}

# Load the sites config

if (-not (Test-Path -Path $SitesConfig)) {
    Write-Error "SitesConfig file does not exist: $SitesConfig"
    exit 1
}
$s_sitesConfigPath = (Resolve-Path -Path $SitesConfig).Path                            # Absolute path of the resolved sites config file
$array_dict_sites = Import-PowerShellDataFile -Path $s_sitesConfigPath                 # Array of site-hashtable entries parsed from the .psd1 (safe-mode load; no script execution)

if ($null -eq $array_dict_sites -or $array_dict_sites.Count -eq 0) {
    Write-Error "SitesConfig file contains no site entries: $s_sitesConfigPath"
    exit 1
}

# Resolve OutputRoot, creating it if necessary

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$s_outputRootAbsolute = (Resolve-Path -Path $OutputRoot).Path                          # Absolute path of the output-root directory after creation

Write-Output "Loaded $($array_dict_sites.Count) site(s) from $s_sitesConfigPath"
Write-Output "Output root: $s_outputRootAbsolute"

# Iterate sites and invoke mirror.ps1 for each

$array_dict_results = @()                                                              # Per-site outcome records used to build the final summary
$date_batchStart = Get-Date                                                            # Batch-level wall-clock start time

# Loop through every configured site (or just the one named by -OnlySite) and mirror it via the single-site script
foreach ($dict_site in $array_dict_sites) {
    if ($OnlySite -and ($dict_site.Name -ne $OnlySite)) {
        continue
    }

    # Validate required fields on this site entry
    if ([string]::IsNullOrWhiteSpace($dict_site.Name)) {
        Write-Warning "Skipping a site entry with no 'Name' field."
        continue
    }
    if ([string]::IsNullOrWhiteSpace($dict_site.Url)) {
        Write-Warning "Skipping site '$($dict_site.Name)' — no 'Url' field."
        continue
    }

    $s_siteOutputDir = Join-Path $s_outputRootAbsolute $dict_site.Name                 # Per-site output folder under OutputRoot
    $array_s_rewriteRules = @()                                                        # Rewrite rules to pass through; empty if site has none
    if ($dict_site.ContainsKey('RewriteRule') -and $null -ne $dict_site.RewriteRule) {
        $array_s_rewriteRules = @($dict_site.RewriteRule)
    }

    Write-Output ""
    Write-Output "================================================================"
    Write-Output "Site: $($dict_site.Name)"
    Write-Output "  URL:        $($dict_site.Url)"
    Write-Output "  Output:     $s_siteOutputDir"
    Write-Output "================================================================"

    $b_success = $false                                                                # Whether the per-site mirror.ps1 invocation succeeded
    $date_siteStart = Get-Date                                                         # Per-site start time, used for the duration column in the summary
    try {
        & $s_mirrorScript `
            -Url $dict_site.Url `
            -OutputDir $s_siteOutputDir `
            -MaxDepth $MaxDepth `
            -RewriteRule $array_s_rewriteRules `
            -Verbose
        $b_success = ($LASTEXITCODE -eq 0)
    }
    catch {
        Write-Warning "Site $($dict_site.Name) threw an exception: $_"
    }
    $date_siteEnd = Get-Date

    $array_dict_results += @{
        Name = $dict_site.Name
        Success = $b_success
        DurationSeconds = [int]($date_siteEnd - $date_siteStart).TotalSeconds
    }
}

$date_batchEnd = Get-Date

# Print the final summary table

Write-Output ""
Write-Output "================================================================"
Write-Output "Batch mirror summary"
Write-Output "================================================================"
# Loop through per-site results and print a one-line OK/FAILED status with duration
foreach ($dict_result in $array_dict_results) {
    $s_status = if ($dict_result.Success) { "OK    " } else { "FAILED" }
    Write-Output ("  [{0}]  {1,-40}  {2,5}s" -f $s_status, $dict_result.Name, $dict_result.DurationSeconds)
}

$n_totalSeconds = [int]($date_batchEnd - $date_batchStart).TotalSeconds                # Total wall-clock duration across all processed sites
$n_failedCount = ($array_dict_results | Where-Object { -not $_.Success }).Count        # Count of sites whose mirror.ps1 invocation did not exit with code 0
Write-Output ""
Write-Output "Total time: $n_totalSeconds seconds across $($array_dict_results.Count) site(s); $n_failedCount failure(s)."

# Exit code: 0 if every processed site succeeded, 1 if any failed. Useful for CI/scheduler integration.
if ($n_failedCount -gt 0) {
    exit 1
}
exit 0
