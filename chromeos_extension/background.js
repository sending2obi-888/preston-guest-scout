const APP_BASE_URL = 'http://localhost:8080';
const DELIVERED_KEY = 'preston_delivered_notification_ids';

// Automatically boot Preston Guest Scout when the Googlebook starts / signs in
chrome.runtime.onStartup.addListener(async () => {
  chrome.alarms.create('preston_match_notification_poll', { periodInMinutes: 1 });
  const existing = await chrome.tabs.query({ url: `${APP_BASE_URL}/*` });
  if (existing.length === 0) {
    await chrome.windows.create({
      url: APP_BASE_URL,
      type: 'popup',
      width: 1180,
      height: 820,
      focused: true,
    });
  }
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.alarms.create('preston_match_notification_poll', { periodInMinutes: 1 });
});

async function pollNewMatchNotifications() {
  try {
    const res = await fetch(`${APP_BASE_URL}/api/notifications`);
    if (!res.ok) return;
    const data = await res.json();
    const list = Array.isArray(data.notifications) ? data.notifications : [];
    if (list.length === 0) return;

    const stored = await chrome.storage.local.get([DELIVERED_KEY]);
    const deliveredSet = new Set(
      Array.isArray(stored[DELIVERED_KEY]) ? stored[DELIVERED_KEY] : []
    );

    let changed = false;
    for (const n of list) {
      if (!n || !n.id || deliveredSet.has(n.id) || n.read) continue;
      deliveredSet.add(n.id);
      changed = true;

      const subParts = [];
      if (n.price) subParts.push(`$${Number(n.price).toLocaleString()}`);
      if (n.location) subParts.push(n.location);

      chrome.notifications.create(`preston_match::${n.guestId}::${n.id}`, {
        type: 'basic',
        iconUrl: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
        title: n.message,
        message: subParts.length > 0 ? `${subParts.join(' • ')} — Click to view match` : n.message,
        priority: 2,
      });
    }

    if (changed) {
      const capped = Array.from(deliveredSet).slice(-500);
      await chrome.storage.local.set({ [DELIVERED_KEY]: capped });
    }
  } catch (_) {}
}

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'preston_match_notification_poll') {
    pollNewMatchNotifications();
  }
});

chrome.notifications.onClicked.addListener((notifId) => {
  if (!notifId.startsWith('preston_match::')) return;
  const parts = notifId.split('::');
  const guestId = parts[1] || '';
  const targetUrl = guestId
    ? `${APP_BASE_URL}/?guestId=${encodeURIComponent(guestId)}`
    : APP_BASE_URL;
  chrome.tabs.create({ url: targetUrl });
});
