const APP_BASE_URL = 'http://localhost:8080';

async function loadRecentTenGuests() {
  const listEl = document.getElementById('guest-list');
  const subtitleEl = document.getElementById('subtitle');

  try {
    const res = await fetch(`${APP_BASE_URL}/api/widget/recent-guests`);
    const data = await res.json();
    const guests = (data.guests || []).slice(0, 10);

    subtitleEl.textContent = `Last 10 Guests Input (${guests.length}/10)`;
    listEl.innerHTML = '';

    if (guests.length === 0) {
      listEl.innerHTML = '<li class="empty">No guests input yet. Click to open app.</li>';
      listEl.onclick = () => chrome.tabs.create({ url: APP_BASE_URL });
      return;
    }

    for (const guest of guests) {
      const li = document.createElement('li');
      li.className = 'guest-row';

      const nameSpan = document.createElement('span');
      nameSpan.className = 'guest-name';
      nameSpan.textContent = guest.name;
      li.appendChild(nameSpan);

      if (guest.matchCount > 0) {
        const badge = document.createElement('span');
        badge.className = 'badge';
        badge.textContent = `${guest.matchCount} match${guest.matchCount === 1 ? '' : 'es'}`;
        li.appendChild(badge);
      }

      li.addEventListener('click', () => {
        const targetUrl = `${APP_BASE_URL}/?guestId=${encodeURIComponent(guest.id)}`;
        chrome.tabs.create({ url: targetUrl });
      });

      listEl.appendChild(li);
    }
  } catch {
    listEl.innerHTML =
      '<li class="empty">Backend offline on localhost:8080. Start preston_guest_scout backend first.</li>';
  }
}

loadRecentTenGuests();
