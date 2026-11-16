const APP_BASE_URL = 'http://localhost:8080';

// Automatically boot Preston Guest Scout when the Googlebook starts / signs in
chrome.runtime.onStartup.addListener(async () => {
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
