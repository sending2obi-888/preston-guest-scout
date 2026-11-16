# Preston Motor Guest Scout

A **Material Design 3** multi-platform **Flutter (Android + Web)** application and **Gemini Agent** backend service that ingests guest target vehicle specifications and automatically searches **[prestonmotor.com](https://www.prestonmotor.com)** twice daily (**7:30 AM** and **2:00 PM**) for matching vehicles across all Preston Automotive Group dealerships.

---

## Key Capabilities

1. **Material Design 3 Experience (`useMaterial3: true`)**
   - Adaptive navigation (`NavigationRail` on Googlebook/Chromebook widescreen, `NavigationBar` on compact screens) with light and dark tonal palettes.
2. **Two Core Pages + Match Drill-Down**
   - **Page 1 — Home (Guest & Vehicle Intake)**: Input a guest's name and target vehicle requirements using both structured specifications (Condition, Year range, Make, Model, Trim, Max Price, Max Mileage, Drivetrain, Color) and free-form Must-Have Features & Notes. Supports **unlimited guest inputs**.
   - **Page 2 — Monitored Guests**: Displays every guest whose requirements are being searched twice daily (`7:30 AM` & `2:00 PM`).
     - **Clicking a guest** opens their **Found Matches** screen (`GuestMatchesScreen`).
     - **Selecting a match** opens `MatchDetailScreen` displaying the vehicle's **Price**, **Dealership Location**, **Date Match Was Found**, and the **Specific Features** that satisfy the guest's previously input requirements.
3. **Twice-Daily (7:30 AM & 2:00 PM) Gemini Agent Search**
   - Fetches live inventory from `prestonmotor.com` (New & Pre-Owned/CPO) and evaluates candidates with **Google Gemini (`gemini-2.5-flash`)** using structured JSON output (`responseSchema`).
   - Includes wake-up catch-up logic if the Googlebook lid was closed at 7:30 AM or 2:00 PM, plus an on-demand **Search Now** button.
4. **Launcher Widget (Strictly Last 10 Guests Input)**
   - **Android / Googlebook ARCVM**: `PrestonGuestWidgetProvider` + `PrestonGuestWidgetService` (`RemoteViewsService` `ListView`) displays **only the names of the last 10 guests input** and deep-links (`prestonscout://guest/<id>`) straight to that guest's vehicle list.
   - **ChromeOS Shelf / Browser**: `chromeos_extension/` popup widget + in-app **Launcher Widget (Last 10)** preview.
5. **Boot at Startup on Googlebook (Chromebook)**
   - **Android Subsystem**: `BootCompletedReceiver` (`RECEIVE_BOOT_COMPLETED` / `LOCKED_BOOT_COMPLETED`) launches `MainActivity` automatically on device startup.
   - **ChromeOS Browser & Linux**: `chromeos_extension/background.js` (`chrome.runtime.onStartup`) auto-opens the app window at Chromebook sign-in, paired with `scripts/install-chromebook-autostart.sh` (`systemd --user` service) for the backend.

---

## Quick Start

### 1. Build Flutter Web & Start the Full-Stack Server

```bash
# Build Flutter Web bundle
cd flutter_app
flutter build web --release

# Start Backend + Scheduled Gemini Agent + Static Web Host (Port 8080)
cd ../backend
GEMINI_API_KEY="your_api_key_here" npm start
```

*(You can also enter or update your `GEMINI_API_KEY` directly inside the app's Settings dialog.)*

### 2. Googlebook (Chromebook) Startup & Widget Setup

- **Option A — ChromeOS Web + Extension Widget**:
  1. Run `./scripts/install-chromebook-autostart.sh` in your Chromebook Linux terminal so the backend & 7:30 AM / 2:00 PM scheduler start automatically on boot.
  2. Open `chrome://extensions`, enable **Developer mode**, click **Load unpacked**, and select `chromeos_extension/`. Pin the extension to the toolbar for instant access to the **Last 10 Guests** widget and automatic startup window launch.
- **Option B — Android APK on Chromebook (ARCVM)**:
  ```bash
  cd flutter_app
  flutter build apk --dart-define=API_BASE_URL=http://<backend-host>:8080
  adb install build/app/outputs/flutter-apk/app-release.apk
  ```
