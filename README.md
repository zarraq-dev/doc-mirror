# doc-mirror

A standalone PowerShell tool for creating offline mirrors — in HTML and Markdown, with media assets — of online developer documentation, technical API references, and design specifications, to enable offline browsing.

Modern documentation sites no longer ship their content as static HTML. They render it client-side from JavaScript, often after several rounds of API calls and DOM mutations. A traditional fetcher, such as `wget` or `curl`, would return only the empty shell in this curcumstance. To mirror a site of this kind for offline reading or full-text search, this tool that performs the capture through executing the page's JavaScript before serialising the result.

`doc-mirror` does this by wrapping [`single-file-cli`](https://github.com/gildas-lormeau/single-file-cli) — which drives a headless Chromium — to capture each page after the JavaScript has populated it, then converts the result to Markdown via [`pandoc`](https://pandoc.org). The output is a directory of self-contained HTML files paired with their Markdown equivalents, plus an `assets/` subfolder containing the extracted images.

The tool is designed to address the problem of documentation sites that a project requires for offline reference returnnig empty shells when fetched with plain HTTP utilities. The remedy is straightforward — render the page in a real browser, then serialise — but a number of practical complications arise when crawling real documentation sites. The Known Issues section at the end of this document records each complication that has been observed in practice, together with the recommended mitigation.

The tool ships in two variants:

| Tool | Purpose |
|---|---|
| `mirror.ps1` | Mirror a single site from a URL. |
| `batch-mirror.ps1` | Mirror several sites in one run, configured by a `sites.psd1` data file. |

Both produce the same per-site output layout. Downstream consumers — text editors, full-text search tools, AI coding assistants — operate identically whether the input is one mirrored site or many.

---

## Comparison with `wget` / `curl` / `httrack`?

Plain HTTP fetchers do not execute JavaScript. Modern documentation platforms such as MkDocs Material, Docusaurus, and VuePress ship a near-empty HTML shell at request time and render the actual content in the browser at runtime. A `wget --mirror` against a site of this kind returns a directory of stubs in which the substantive content is absent.

`doc-mirror` drives a headless Chromium process. Each page loads in a real browser context, JavaScript executes, the DOM mutates into its final state, and only then does the tool serialise the page to disk. The saved artefact corresponds to what a user would see in their browser.

---

## Requirements

| Dependency | Purpose | Install |
|---|---|---|
| PowerShell 7 or newer | Host runtime for the scripts. Windows PowerShell 5.1 functions for most operations but has known encoding quirks; PowerShell 7+ is the recommended target. | `winget install Microsoft.PowerShell` |
| Node.js | Required by `single-file-cli`. | `winget install OpenJS.NodeJS.LTS` |
| `single-file-cli` | The crawler and page-capture engine. | `npm install -g single-file-cli` |
| `pandoc` | HTML-to-Markdown conversion. | `winget install JohnMacFarlane.Pandoc` |

Verify each dependency is on `PATH` before running the tool:

```powershell
node --version
npm --version
single-file --version
pandoc --version
```

---

## Mirroring a single site

```powershell
.\mirror.ps1 `
    -Url "https://example.com/docs/" `
    -OutputDir ".\example-docs-mirror"
```

On completion, the output directory contains:

```
example-docs-mirror/
├── Getting started.html       ← self-contained HTML, fully rendered
├── Getting started.md         ← Markdown produced by pandoc
├── ...one .html and .md pair per discovered page...
├── assets/                    ← images referenced from the .md
└── manifest.json              ← crawl date, source URL, tool versions, file counts
```

The full set of parameters — including `-MaxDepth`, `-RewriteRule`, and the browser-tuning flags — is documented in the comment-based help:

```powershell
Get-Help .\mirror.ps1 -Detailed
```

---

## Mirroring several sites at once

The batch tool consumes a configuration file that lists the sites to be mirrored.

1. Copy the example configuration to a real one. The real one is gitignored so that it cannot leak to a public repository:

    ```powershell
    Copy-Item .\sites.example.psd1 .\sites.psd1
    ```

2. Edit `sites.psd1` to list the target sites. The format is documented in the next section.

3. Invoke the batch tool, supplying the configuration path and an output root directory:

    ```powershell
    .\batch-mirror.ps1 -SitesConfig .\sites.psd1 -OutputRoot .\mirrors
    ```

Each configured site lands in `mirrors/<site.Name>/`, with the layout that single-site mode produces.

Useful flags:

- `-OnlySite <name>` restricts the run to a single site from the configuration. This is useful when iterating on the rewrite rules for one specific site without re-running the full batch.
- `-MaxDepth <n>` caps crawl depth across all sites. The default is `0`, which permits unbounded depth. This default is safe in practice because the crawler cannot escape the URL subtree, thanks to the `--crawl-no-parent` constraint that `mirror.ps1` always enforces.

---

## The sites configuration file

`sites.psd1` is a PowerShell data file containing a literal hashtable; no script execution takes place when the file is read. The shape is straightforward:

```powershell
@(
    @{
        Name        = "example-site-one"             # folder name for this site's output
        Url         = "https://example.com/docs/"    # starting URL for the crawl
        RewriteRule = @(                             # optional URL rewrite rules
            '^(.*?)\?.*$ $1'                         # strip query strings
        )
    },

    @{
        Name = "example-site-two"
        Url  = "https://docs.another-example.com/"
        RewriteRule = @(
            '^(.*?)\?.*$ $1'
        )
    }
)
```

### Rewrite rules

A rewrite rule is a single string of the form `"<regex> <replacement>"`, with the two parts separated by whitespace. The rule is applied to every URL the crawler discovers prior to fetching it. A rule that rewrites a URL to an empty string causes that URL to be dropped from the crawl entirely.

| Goal | Rule |
|---|---|
| Strip query strings, deduplicating URLs that differ only by tracking parameters | `'^(.*?)\?.*$ $1'` |
| Rewrite localised path prefixes to canonical English (only when safe — see Known Issues, item 2) | `'^(https://example\.com/docs)/(es\|fr\|ja\|zh\|pt)/ $1/'` |
| Drop matching URLs from the crawl entirely | `'^https://example\.com/internal/'` (no replacement → empty → URL dropped) |

`sites.example.psd1` includes annotated commentary on each field.

---

## Output layout

Each site, regardless of single-site or batch mode, produces:

```
<output-folder>/
├── <Page-Title>.html         (one self-contained HTML per captured page)
├── <Page-Title>.md           (matching Markdown, image refs pointing into assets/)
├── assets/                   (images extracted during pandoc conversion)
└── manifest.json             (tool versions, crawl dates, file counts, source URL)
```

The HTML files are fully self-contained. Each may be opened directly in a browser and will render correctly without any additional files. The Markdown files reference images via the relative `assets/` path.

---

## Re-runs

Both tools wipe the per-site output directory's contents before each crawl: top-level files and the `assets/` subfolder are deleted prior to the new run. Re-runs are therefore idempotent. A given site with a given configuration produces the same output on every invocation; no accumulation of `(N)`-suffixed duplicate files occurs across runs.

Committing the output to a version-control system and re-running periodically yields a diff against the previous commit that shows precisely what changed upstream.

---

## Known issues and limitations

The following limitations have been observed when applying this tool to real documentation sites. Each is paired with a recommended mitigation.

### 1. The crawler captures 404 pages for broken upstream navigation

Many documentation sites contain stale or auto-generated navigation that links to pages which do not actually exist. Typical examples include orphan API property pages (the class is documented, but each individual property's page was never generated), badly-rendered relative paths that produce nonsense URLs, and pages that have been removed but not unlinked from the navigation. The crawler follows every link it discovers and saves whatever the server returns. When the server returns a 404, the crawler saves the 404 response.

These files appear in the output as `404 Not Found.html`, `404 Not Found (2).html`, and so on, with matching `.md` files.

**Mitigation.** After each crawl, sweep them up:

```powershell
Get-ChildItem <OutputDir> -Recurse -Filter "404 Not Found*" | Remove-Item -Force
```

Both tools deliberately leave the 404 files in place rather than auto-cleaning. The design preference is for minimal, predictable behaviour from the supplied tools; any automated cleanup should live in a calling script around `batch-mirror.ps1`.

### 2. Language-code rewrite rules can false-match English path segments

When a documentation site supports multiple languages via path prefixes (`/es/`, `/fr/`, `/ja/`, and so on), a tempting rewrite rule is one that strips the language prefix using a broad pattern such as `[a-z]{2,3}/`. This pattern treats any two- or three-letter lowercase path segment as a language code.

The pattern is unsafe. Legitimate English path segments on documentation sites are commonly two or three letters long: `/faq/`, `/api/`, `/cli/`, `/sdk/`. A broad rule strips these segments too, corrupting real URLs into ones the server cannot serve. The crawler then captures the resulting 404 responses in place of the real content.

Consider, for example, an English-only documentation site that has been mistakenly assumed to be multilingual. A broad rewrite rule of this form will silently corrupt every `/faq/<topic>` URL into `/<topic>`, which the server cannot serve. Entire sections of FAQ content disappear from the mirror — a condition typically detected only when the count of `404 Not Found` files looks suspiciously high.

**Mitigation.** Apply language-code rewrite rules only to sites that genuinely have multi-language paths, and prefer an explicit alternation listing the actual language codes:

```powershell
RewriteRule = @(
    '^(.*?)\?.*$ $1',
    '^(https://example\.com/docs)/(es|fr|ja|ko|pt|ru|zh|ar)/ $1/'
)
```

The explicit alternation cannot match English path segments because none of them appear in the list.

### 3. Per-page capture has a 60-second timeout

`single-file-cli` caps each page's capture at 60 seconds by default. Most pages capture in 1 to 5 seconds. Very heavy pages — long programming tutorials with embedded examples, debugging documentation with profiler output, and similar content — occasionally exceed the limit. When that occurs, `single-file-cli` reports a `Capture timeout` warning and skips the page. No file is produced.

**Mitigation.** For a small number of timed-out pages, capture them individually with a longer timeout:

```powershell
single-file "https://example.com/docs/very-large-page/" `
    --output-directory=".\example-docs-mirror" `
    --filename-template='{page-title}.{filename-extension}' `
    --browser-wait-until=load `
    --browser-wait-delay=2000 `
    --browser-capture-max-time=180000
```

Place the resulting file alongside the rest of the mirror. If a Markdown copy is also required, invoke `pandoc` separately on the new HTML.

### 4. Some pages refuse to render in headless Chrome

Occasionally a page that loads correctly in a regular browser consistently fails when fetched via the headless Chromium that `single-file-cli` drives. The cause varies: server-side bot detection, missing local-storage state on which the page depends, server-side `User-Agent` discrimination, and so on.

**Mitigation.** Capture such pages manually. Open them in a regular browser, use **Ctrl+S → "Webpage, Single File"**, and place the resulting `.html` file in the output folder. The format will differ slightly from what `single-file-cli` produces, but for offline reading and full-text search the difference is not material.

### 5. Do not pass `--filename-conflict-action=overwrite` to single-file

A bug exists in `single-file-cli`, visible in its source at the time of writing, in which setting `--filename-conflict-action=overwrite` causes the returned filename to omit the output-directory prefix. Files are then written to the process's current working directory instead of the configured output location. A typical PowerShell session running from `C:\Windows\System32` produces silent failures, because System32 is write-protected, and the crawl appears to produce zero captured files.

**Mitigation.** `mirror.ps1` does not pass the flag. It instead clears the output directory's contents itself before each crawl, achieving the same clean-re-run semantics without depending on the upstream code path.

---

## How it works

For each URL the tool is to capture:

1. `single-file-cli` launches a headless Chromium, navigates to the URL, and waits for the page to reach the configured load state (controlled by `-BrowserWaitUntil`).
2. After a short post-load delay (`-BrowserWaitDelayMs`, default 2000 ms), `single-file-cli` injects a content script that serialises the fully-rendered DOM. Images are inlined into the HTML as base64 data URIs. CSS and any required JavaScript are inlined too.
3. The serialised page is written to disk as a single self-contained `.html` file.
4. Once all pages are captured, `pandoc` converts each `.html` to a parallel `.md`. Images referenced from the HTML are extracted into a sibling `assets/` folder and replaced with relative references in the Markdown.
5. `mirror.ps1` writes a `manifest.json` recording the crawl date, source URL, page counts, and tool versions.

In crawl mode (which `mirror.ps1` always uses), `single-file-cli` follows internal links from each captured page, subject to:

- `--crawl-inner-links-only=true` — only links on the same domain are followed.
- `--crawl-no-parent=true` — only links within the URL subtree starting at the configured root URL are followed.
- `--crawl-max-depth=<N>` — depth cap from the starting URL.
- Whatever rewrite rules the configuration supplies.

While the crawl runs, a `FileSystemWatcher` event handler in `mirror.ps1` reads the `url:` header from each freshly-saved HTML and reports it to the terminal. The operator observes real-time progress of the form:

```
captured: https://example.com/docs/use-cases/  ->  Use cases.html
captured: https://example.com/docs/api-reference/  ->  API reference.html
```

---

## Coding conventions

The PowerShell in this repository follows the conventions below. They are relevant for anyone wishing to contribute.

- **K&R brace style.** `if ($x) { ... }`, not Allman. This matches the dominant PowerShell community convention.
- **Hungarian notation on internal variables.** Primitives use `$s_`, `$n_`, `$b_`, `$date_`, `$dict_`, `$array_`. Domain types use the type name as the prefix: `$file_` for `FileInfo`, `$watcher_` for `FileSystemWatcher`, and so on.
- **PascalCase on parameters.** Cmdlet parameters follow the public-API convention: `$Url`, `$OutputDir`. Internal variables remain in Hungarian style.
- **Comment-based help on every script and exported function.** Populated `.SYNOPSIS`, `.DESCRIPTION`, `.PARAMETER`, and `.EXAMPLE` sections.
- **Generous inline annotation.** Every variable declaration carries a trailing comment that states the variable's purpose.
- **`$null -eq $x`, not `$x -eq $null`.** Defends against the PowerShell array-filtering footgun.
- **`Write-Verbose`, `Write-Warning`, `Write-Error` over `Write-Host`.** Output traverses the proper streams.

---

## Licence

A licence has not yet been declared. Until a `LICENCE` file is added, the code in this repository is presumed all rights reserved by default. Use of this code requires either an issue to be opened or a fork to be created with a proposed licence.

The wrapped dependencies carry their own licences:

- `single-file-cli` — AGPL
- `pandoc` — GPL
- Node.js — MIT-style (mixed components)

`doc-mirror` invokes both as external processes rather than linking against them, so its own licence is independent of theirs.
