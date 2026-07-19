Cloudflare Pages + Worker deployment guide

1) Structure

- Place site files under the repository path `AppleStorePages/`.
- Localized folders: `/fr/` and `/en/` already exist.

2) Deploy on Cloudflare Pages (quick)

- Create a Git repository and push the project.
- In Cloudflare Pages, create a new project and connect the repository.
- Set the build output directory to `AppleStorePages` (if building static) — but for plain static files no build command is needed.

3) Worker for language redirect

- The file `cloudflare-worker.js` contains a simple redirect based on the `Accept-Language` header.
- To deploy the Worker:
  - Install Wrangler (Cloudflare CLI): `npm i -g wrangler`.
  - Authenticate: `wrangler login`.
  - Create `wrangler.toml` in the `AppleStorePages` folder with content:

```
name = "finance-mobile-lang-redirect"
type = "javascript"
account_id = "<YOUR_ACCOUNT_ID>"
route = "example.com/*"
zone_id = "<YOUR_ZONE_ID>"
```

  - Update `route` to your domain (or use the Pages custom domain).
  - Publish the worker:

```bash
wrangler publish cloudflare-worker.js --name finance-mobile-lang-redirect
```

4) Important notes for App Store

- App Store reviewers may open the Privacy/Terms URL directly; ensure `https://your-domain/en/privacy.html` and `/fr/privacy.html` are reachable independently (don't rely only on the worker redirect).
- Use the direct English URL for App Store Connect if you want reviewers to see English.
- Ensure `apple-app-site-association` is available at `https://your-domain/apple-app-site-association` (no extension) with `Content-Type: application/json`. Cloudflare Pages supports `_headers` to set Content-Type.

5) Testing

- Test Accept-Language handling locally using `curl -H "Accept-Language: fr" https://your-domain/` and with `en` header.

6) Help

If you want, I can:
- create a `wrangler.toml` template with placeholders, or
- prepare a Git repo and example `wrangler` commands customized to your domain.
