// Web Push: shows what the yeoman said while the app is closed or behind
// another, and opens the chat when tapped. The server sends {title, body,
// tag}; one tag per kind, so a burst leaves only the latest notification.
self.addEventListener("push", (event) => {
  const note = event.data ? event.data.json() : {};
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((open) => {
      // The person is looking at the chat already.
      if (open.some((c) => c.visibilityState === "visible" && c.focused)) return;
      return self.registration.showNotification(note.title || "Chat", {
        body: note.body,
        tag: note.tag,
        renotify: true,
        icon: "/_site/icon-192.png",
      });
    }),
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((open) => {
      const chat = open[0];
      return chat ? chat.focus() : self.clients.openWindow("/");
    }),
  );
});
