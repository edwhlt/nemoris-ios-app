Pages pour App Store Connect

Fichiers statiques pour fournir les URLs nécessaires à App Store Connect (Privacy Policy, Support, Marketing, Terms) et le fichier `apple-app-site-association` pour les Universal Links / Associated Domains.

Remarques:
- Remplacez `TEAMID.com.your.bundleid` dans `apple-app-site-association` par votre `TeamID` et l'`App ID`.
- Les hébergeurs recommandés (faciles et gratuits): Netlify, Vercel, Cloudflare Pages. GitHub Pages peut fonctionner pour les pages HTML, mais poser des contraintes pour `apple-app-site-association` sans configuration d'en-têtes.

Déploiement rapide (exemples):

- Netlify: créer un site depuis ce dossier (drag & drop) ou depuis un repo Git. Assurez-vous que `_headers` est inclus pour forcer `Content-Type: application/json` sur `apple-app-site-association`.
- Vercel: `vercel` CLI ou importer le repo; `vercel.json` définit les en-têtes nécessaires.
- Cloudflare Pages: importer le repo; il supporte `_headers` comme Netlify.

Fichiers créés:
- `index.html` (marketing)
- `privacy.html` (politique de confidentialité)
- `support.html` (support)
- `terms.html` (conditions)
- `apple-app-site-association` (JSON, sans extension)
- `_headers` (Netlify/Cloudflare headers)
- `vercel.json` (headers pour Vercel)

Voulez-vous que je prépare aussi un dépôt Git et un guide pas-à-pas pour déployer sur Netlify ou Vercel ?
