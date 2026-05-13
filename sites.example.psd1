#
# Example sites configuration for batch-mirror.ps1
# ================================================
#
# Copy this file to sites.psd1 (the actual filename consumed by batch-mirror.ps1).
# sites.psd1 is gitignored so your real site list never gets committed to a public repo.
#
# Once you have sites.psd1, run:
#
#     .\batch-mirror.ps1 -SitesConfig .\sites.psd1 -OutputRoot .\out
#
# Each entry below is a PowerShell hashtable with the following keys:
#
#   Name         Folder name used for this site's output. Use a slug — no spaces,
#                no special characters. Output goes to <OutputRoot>/<Name>/.
#
#   Url          Starting URL for the crawl. The crawler stays within this URL's
#                path subtree (does not ascend above it) and within the same domain.
#
#   RewriteRule  (Optional) An array of regex rewrite rules applied to every URL
#                discovered during the crawl. Each rule is a string of the form
#                "<regex-pattern> <replacement>" (parts separated by whitespace).
#                Rules that rewrite a URL to an empty string drop that URL from
#                the crawl entirely (useful for filtering out known-bad paths).
#
# See the README for further detail on rewrite rules, known caveats, and how
# to choose appropriate patterns for a given site.
#

@(
    @{
        Name = "example-site-one"
        Url = "https://example.com/docs/"

        RewriteRule = @(
            # Strip query strings — deduplicates URLs that differ only by tracking parameters
            # such as ?utm_source=... or ?ref=.... Recommended for most sites.
            '^(.*?)\?.*$ $1'
        )
    },

    @{
        Name = "example-site-two"
        Url = "https://docs.another-example.com/"

        RewriteRule = @(
            '^(.*?)\?.*$ $1'

            # If your site has localised path prefixes (e.g. /es/, /fr/, /ja/, /zh/),
            # a rule like the one below maps non-English path prefixes back to the
            # canonical English equivalent, deduplicating multi-language captures.
            #
            # Important caveat: the pattern [a-z]{2,3} will match ANY 2–3 letter
            # lowercase path segment, including legitimate English ones such as
            # /faq/ or /api/. Only enable this rule after manually verifying that
            # no English path segments on your site are 2–3 letters long, or
            # use an explicit list of language codes:
            #
            #   '^(https://docs\.another-example\.com)/(es|fr|ja|zh|pt|ru|de|it|nl)/ $1/'
            #
            # See "Known caveats" in the README for the full discussion.
        )
    }
)
