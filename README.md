# doc-mirror

Standalone tool to mirror a developer documentation site as local HTML + Markdown files. Suitable for offline reading, grep, and AI-assisted code generation against the docs.

## What it does

Given a URL (e.g. `https://help.ctrader.com/ctrader-algo/`) and an output directory, the tool:

1. **Crawls the site** using [`single-file-cli`](https://github.com/gildas-lormeau/single-file-cli) — a headless Chromium-based capture tool that renders JavaScript correctly, including modern single-page-application doc sites where plain HTTP fetchers like `wget` get only the empty page shell.
2. **Saves each page** as a fully self-contained `.html` file (images, CSS, JS all inlined).
3. **Converts each HTML** to a parallel `.md` file via [`pandoc`](https://pandoc.org), with images extracted into an `assets/` folder and referenced from the Markdown.
4. **Writes a `manifest.json`** capturing the crawl date, source URL, file counts, and tool versions for reproducibility.

The output is git-friendly (no inlined base64 in the Markdown), grep-friendly (Markdown text), and diffs cleanly when docs are re-mirrored after upstream updates.

## Requirements

- **PowerShell 7+** (the script also works in Windows PowerShell 5.1 with minor encoding caveats)
- **Node.js** (for `single-file-cli`)
- **`single-file-cli`** on PATH: `npm install -g single-file-cli`
- **`pandoc`** on PATH: `winget install JohnMacFarlane.Pandoc` (or your platform's equivalent)

## Usage

```powershell
.\mirror.ps1 -Url <root-url> -OutputDir <path> [-MaxDepth <n>] [-SkipMarkdown] [-Verbose]
```

### Examples

Mirror cTrader's Open API docs to a local folder:

```powershell
.\mirror.ps1 -Url "https://help.ctrader.com/open-api/" -OutputDir "C:\docs\ctrader-open-api"
```

Mirror with a custom crawl depth, skipping Markdown conversion (debug the crawl phase only):

```powershell
.\mirror.ps1 -Url "https://example.com/docs/" -OutputDir ".\out" -MaxDepth 10 -SkipMarkdown
```

For full parameter help and additional examples:

```powershell
Get-Help .\mirror.ps1 -Detailed
```

## Output layout

```
<OutputDir>/
├── <page-title>.html       (one self-contained HTML per page; SPA content fully rendered)
├── <page-title>.md         (matching Markdown per page; images replaced with references into assets/)
├── assets/                 (image files extracted from HTML during pandoc conversion)
└── manifest.json           (run metadata for reproducibility: dates, counts, tool versions)
```

## Re-runs

Running the tool again against the same `OutputDir` overwrites existing files at the same paths. The crawl is deterministic — same site, same output — so you can diff successive `manifest.json` files (and the Markdown content itself) to detect upstream documentation changes.

## Coding standards

This script follows the conventions documented in [POWERSHELL.md](../standards/coding-standards/POWERSHELL.md). Notable choices for PowerShell specifically:

- K&R / OTBS bracing (the PowerShell community convention; deviates from project-wide Allman because PowerShell standards override here)
- Hungarian notation on internal variables; PascalCase for cmdlet parameters (matching the public-API idiom)
- Comment-based help block at the top for `Get-Help` integration
- Explicit type annotations on parameters and most local variables
- Verb-Noun naming for internal helper functions

## License

(Add a license if/when this becomes a shared tool. Personal use for now.)
