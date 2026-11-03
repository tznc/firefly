// Firefly's service worker, served from the site root so its scope is the
// whole site: it shows browser push notifications (see Firefly.WebPush)
// and opens the notification's page when one is clicked. Registering it
// also makes the site installable (with /manifest.json).

self.addEventListener("push", event => {
  const data = event.data ? event.data.json() : {}

  event.waitUntil(self.registration.showNotification(data.title || "Firefly", {
    body: data.body,
    tag: data.tag,
    icon: "/images/icon-192.png",
    badge: "/images/favicon-32.png",
    data: {url: data.url || "/"},
  }))
})

self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = new URL(event.notification.data.url, self.location.origin)

  event.waitUntil(self.clients.matchAll({type: "window", includeUncontrolled: true}).then(windows => {
    const open = windows.find(w => new URL(w.url).origin === url.origin && "focus" in w)
    if (open) { return open.navigate(url.href).then(w => (w || open).focus()) }
    return self.clients.openWindow(url.href)
  }))
})
