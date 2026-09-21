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
