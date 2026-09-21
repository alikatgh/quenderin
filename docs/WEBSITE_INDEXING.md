# Website indexing

September 21, 2026: Search Console reported clean URLs as alternates because
canonical tags pointed back to `.html` addresses. The apex Cloudflare Worker
redirects those `.html` addresses to clean URLs. Canonicals, structured-data
URLs, HTML navigation links and the 20-entry sitemap now use the final URLs.
The `website/*.html` filenames and existing redirect behavior are unchanged.

Checked all 20 sitemap entries against local files and canonical tags, plus
internal HTML links. No app, download artifact, or backend changes are included.

Previous production Worker version (rollback):
`0b50a219-9e95-4d57-9a81-a782e8eada9f`.
Deploy the apex with `npx wrangler@4 deploy --config wrangler.site.jsonc`.

## Production verification — September 21, 2026

Approved release `a0c028c` was fast-forwarded to `main` and deployed to the apex
Worker, version `2e14ca3d-c967-4e7c-8069-aadc0526d971`.
All 20 live sitemap URLs return 200 without redirects, are indexable, and have
exact self-canonical tags; the served sitemap matches the release byte for byte.
Google accepted the resubmitted sitemap. Validation of the five reported
canonical alternates started September 21. Reindexing is not yet confirmed.
