addEventListener("fetch", event => {
  event.respondWith(handle(event.request))
})

async function handle(req) {
  const url = new URL(req.url)
  // Allow direct access to localized paths and known assets/AASA
  if (url.pathname.startsWith('/fr/') || url.pathname.startsWith('/en/') || url.pathname === '/apple-app-site-association' || url.pathname.startsWith('/.well-known/')) {
    return fetch(req)
  }

  // If request is for root or unknown path, redirect based on Accept-Language
  const accept = req.headers.get('Accept-Language') || ''
  const prefersFr = accept.toLowerCase().startsWith('fr') || accept.includes('fr-')
  const target = prefersFr ? '/fr/' : '/en/'
  return Response.redirect(url.origin + target, 302)
}
