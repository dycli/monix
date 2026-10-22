import { useEffect, useState } from "react";

// Notifications through Web Push: the service worker (public/sw.js) shows
// them, the server (push.rs) sends them to every device that turned the
// bell on.

export type Bell = "unsupported" | "off" | "on" | "denied";

const supported = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;

function b64url(buf: ArrayBuffer | null): string {
  if (!buf) return "";
  return btoa(String.fromCharCode(...new Uint8Array(buf)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function key(): Promise<string | null> {
  const r = await fetch("api/push");
  return r.ok ? r.text() : null;
}

/** Subscribes this device, or renews its subscription when the server's key
 * changed; tells the server either way, so a lost device list fills in. */
async function subscribe(reg: ServiceWorkerRegistration): Promise<boolean> {
  const k = await key();
  if (!k) return false;
  let sub = await reg.pushManager.getSubscription();
  if (sub && b64url(sub.options.applicationServerKey) !== k) {
    await sub.unsubscribe();
    sub = null;
  }
  sub ??= await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: k });
  const r = await fetch("api/push", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(sub.toJSON()),
  });
  return r.ok;
}

export function usePush(): [Bell, () => void] {
  const [bell, setBell] = useState<Bell>(supported ? "off" : "unsupported");
  const [reg, setReg] = useState<ServiceWorkerRegistration | null>(null);

  useEffect(() => {
    if (!supported) return;
    // From the root even in a pane of the split, so one worker, and one
    // subscription, serves every assistant on the host.
    navigator.serviceWorker
      .register("/sw.js")
      .then(async (r) => {
        setReg(r);
        if (Notification.permission === "denied") return setBell("denied");
        if (Notification.permission === "granted" && (await r.pushManager.getSubscription())) {
          setBell((await subscribe(r)) ? "on" : "off");
        }
      })
      .catch((e) => console.error("push:", e));
  }, []);

  const toggle = async () => {
    if (!reg) return;
    try {
      if (bell === "on") {
        const sub = await reg.pushManager.getSubscription();
        if (sub) {
          await fetch("api/push/drop", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ endpoint: sub.endpoint }),
          });
          await sub.unsubscribe();
        }
        return setBell("off");
      }
      const p = await Notification.requestPermission();
      if (p !== "granted") return setBell(p === "denied" ? "denied" : "off");
      setBell((await subscribe(reg)) ? "on" : "off");
    } catch (e) {
      console.error("push:", e);
    }
  };

  return [bell, toggle];
}
