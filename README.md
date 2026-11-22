# Preston Motor Guest Scout

A **Material Design 3** multi-platform **Flutter (Android + Web)** application and **Gemini Agent** backend service that ingests guest target vehicle specifications and automatically searches **[prestonmotor.com](https://www.prestonmotor.com)** twice daily (**7:30 AM** and **2:00 PM**) for matching vehicles across all Preston Automotive Group dealerships.

---

## Key Capabilities

1. **Material Design 3 Experience (`useMaterial3: true`)**
   - Adaptive navigation (`NavigationRail` on Googlebook/Chromebook widescreen, `NavigationBar` on compact screens) with light and dark tonal palettes.
2. **Three Core Pages + Match Drill-Down**
   - **Page 1 — Home (Guest & Vehicle Intake)**: Input a guest's name and target vehicle requirements using both structured specifications (Condition, Year range, Make, Model, Trim, **Number of Doors** (`Any`, `2 Doors`, `3 Doors`, `4 Doors`, `5 Doors`), Max Price, Max Mileage, Drivetrain, **multi-select Exterior Colors** with paint swatches & custom OEM colors matching any selected color) and free-form Must-Have Features & Notes. Supports **unlimited guest inputs**.
   - **Page 2 — Monitored Guests**: Displays every guest whose requirements are being searched twice daily (`7:30 AM` & `2:00 PM`).
     - **Clicking a guest** opens their **Vehicle Matches** screen (`GuestMatchesScreen`).
     - **Client Notes Dropdown Above Target Vehicles**: Directly above each guest's Target Vehicles section, a **Client Notes** dropdown displays the **most recent note** immediately without opening the dropdown, includes an input field to save new notes, and expands to show every saved note with the exact date & time it was added.
     - **Edit Search After Initial Search + Add Unlimited Vehicles per Guest**: Inside any guest's Vehicle Matches page, tap **Edit Search** on any monitored vehicle (or in the top AppBar) to modify Make, Model, Trim, Number of Doors, Year range, Budget, Mileage, Drivetrain, Truck Bed Length, multi-select Exterior Colors, Features, or Natural-Language Criteria — clearing stale matches and immediately re-searching `prestonmotor.com` — or tap **Add Another Vehicle** to monitor additional vehicles alongside existing criteria.
     - **One-Click Copy for VIN & Stock Numbers**: Clicking any displayed **VIN** (`VIN: <VIN>`) or **Stock Number** (`Stock #<Stock>`) across vehicle match cards, match detail screens, notifications, and recall checks immediately copies the clean VIN or Stock number to the clipboard with instant visual confirmation.
     - **Selecting a match** opens `MatchDetailScreen` displaying the vehicle's **Price**, **Dealership Location**, **Date Match Was Found**, one-click copyable **VIN** & **Stock #** badges, a one-tap **Check NHTSA Recalls** button, and the **Specific Features** that satisfy the guest's previously input requirements.
   - **Page 3 — VIN Recall Check (`www.nhtsa.gov/recalls` + Gemini — Complete vs. Incomplete)**: Enter any 17-character VIN to decode factory specifications via NHTSA vPIC, reconcile official NHTSA safety recall campaigns with live per-VIN Open Recall completion records, and have **Gemini (`gemini-2.5-flash`)** clearly differentiate **Incomplete (Open)** recalls (including `Remedy Not Available`, `DO NOT DRIVE`, and `Park Outside` warnings) from **Complete (Closed on VIN)** recalls, with interactive `All` / `Incomplete` / `Complete` filter chips and one-click `Mark Complete` / `Mark Incomplete` dealership service tracking.
3. **Twice-Daily (7:30 AM & 2:00 PM) Gemini Agent Search**
   - Fetches live inventory from `prestonmotor.com` (New & Pre-Owned/CPO) across all pages and evaluates every guest's vehicle targets independently with **Google Gemini (`gemini-2.5-flash`)** using structured JSON output (`responseSchema`).
   - Includes wake-up catch-up logic if the Googlebook lid was closed at 7:30 AM or 2:00 PM, plus an on-demand **Search Now** button.
4. **Launcher Widget (Strictly Last 10 Guests Input)**
   - **Android / Googlebook ARCVM**: `PrestonGuestWidgetProvider` + `PrestonGuestWidgetService` (`RemoteViewsService` `ListView`) displays **only the names of the last 10 guests input** and deep-links (`prestonscout://guest/<id>`) straight to that guest's vehicle list.
   - **ChromeOS Shelf / Browser**: `chromeos_extension/` popup widget + in-app **Launcher Widget (Last 10)** preview.
5. **Boot at Startup on Googlebook (Chromebook)**
   - **Android Subsystem**: `BootCompletedReceiver` (`RECEIVE_BOOT_COMPLETED` / `LOCKED_BOOT_COMPLETED`) launches `MainActivity` automatically on device startup.
   - **ChromeOS Browser & Linux**: `chromeos_extension/background.js` (`chrome.runtime.onStartup`) auto-opens the app window at Chromebook sign-in, paired with `scripts/install-chromebook-autostart.sh` (`systemd --user` service) for the backend.
6. **Google Single Sign-On (SSO) & Multi-Device Google Drive Sync**
   - **Google SSO Across Devices**: Sign in using native Android / Googlebook OS Google Account Picker (`AccountManager` + `GoogleAuthUtil` with non-sensitive `drive.file` scope), Googlebook-safe OAuth 2.0 Verification Code Flow (`google.com/device`), OAuth 2.0 PKCE Loopback SSO, optional Preston Sync Server Relay, or Google Identity Services on Web.
   - **Automatic Save to Google Drive**: Every new guest, client note, added/removed vehicle target, requirement edit, deletion tombstone, and vehicle search result is automatically saved to `preston_guest_scout_cloud_sync.json` in Google Drive.
   - **Automatic Query on Every App Open**: Every cold start, app foreground resume (`AppLifecycleState.resumed` / browser tab focus), and Launcher Widget launch automatically queries Google Drive and merges remote updates (including client notes added across multiple devices) conflict-free across all devices.
7. **Full Android Notifications for New Matches After Initial Search**
   - **Silent Initial Search**: Initial intake searches (and the initial search when adding a new vehicle target to an existing guest) record baseline matched VINs silently without spamming notifications.
   - **Full Native Android Heads-Up Notifications (`NotificationCompat`)**: Whenever a **new** matching vehicle (new VIN) is found for a guest **after** their first initial search (`7:30 AM` daily scan, `2:00 PM` daily scan, Google Drive multi-device sync, or manual `Search Now`), Android posts a high-importance (`IMPORTANCE_HIGH`) heads-up notification (`preston_match_alerts_v2`) with a monochrome status-bar car icon (`@drawable/ic_stat_vehicle_match`), default sound, vibration, LED indicator, lock-screen visibility, launcher badge, and `InboxStyle` multi-match grouping.
   - **Guest Name + Vehicle Model Prominently Included**: Every alert displays `"<Guest Name> - Match Found - <Model of vehicle>"`, collapsed summary `"New <Vehicle Model> found for <Guest Name> • <Price> • <Dealership>"`, expanded `BigTextStyle` details, a **"View Match"** deep-link button (`prestonscout://guest/<id>`), and a **"Call <FirstName>"** dialer button when a phone number is on file.
   - **True Background Android Scanning (Even When App Is Closed)**: `BackgroundMatchScanJobService` (`JobScheduler` persisted across reboots) + `DailySearchAlarmReceiver` (`goAsync()`) run `NativeBackgroundMatchScanner` natively on Android 10–15 without Background Activity Launch blocks, plus Web browser `Notification` API, ChromeOS extension tray alerts, and an interactive Notification Center (`Enable OS Alerts`, `Android Settings`, `Test Alert`).
8. **Calendar Permissions & Automatic Same-Day `"Call Guest"` Calendar Events**
   - **Startup Calendar Permission Prompt**: Requests `READ_CALENDAR` & `WRITE_CALENDAR` runtime permissions on Android / Googlebook startup (`MainActivity`), includes Google Calendar `calendar.events` OAuth scope during Google SSO, and presents a Material Design 3 **Allow Calendar Access** prompt (`CalendarPermissionPromptDialog`) plus an AppBar **Same-Day Guest Call Calendar** dialog (`CalendarEventsDialog`).
   - **Automatic Same-Day Call Event When a Match Is Found**: Whenever a matching vehicle is found for a guest while Calendar Permission is granted, the app automatically schedules a **same-day** calendar event (`"Call <Guest Name> — Match Found: <Model>"`) with the guest's phone number, email, latest client note, matched vehicle price, Preston dealership location, listing URL, and a 15-minute popup reminder — stepping past busy calendar slots on that exact same day (`--send-updates none`, zero unsolicited customer invites, deduplicated per guest per day).
9. **Last 5 Backups & Conflict Resolution (`Overwrite` or `Duplicate`) in Settings**
   - **Rolling Last 5 Backups**: Automatically captures point-in-time backups on guest, vehicle target, client note, and pre-delete changes (plus on-demand **Back Up Now** in Settings), retaining the **5 most recent backups** locally and across Google Drive sync.
   - **Inspect & Load Backups in Settings**: Open **Settings** (`SettingsAndChromebookDialog`) to view the last 5 backups, expand **View Backup** to inspect every included guest, target vehicle, note count, and match count, and tap **Load Backup** to restore data.
   - **Overwrite vs. Duplicate Conflict Prompt**: Whenever a selected backup contains entries that conflict with current guests, `BackupConflictResolutionDialog` lets the user choose **Overwrite Entries** (replaces matching guests, vehicles, notes, and matches with the backup) or **Duplicate Entries** (keeps existing entries and imports conflicting backup guests as separate `(Copy)` entries).
10. **Accurate Natural-Language Vehicle Search (`NaturalLanguageVehicleParser`)**
    - **Multi-Sentence & Shorthand Parsing**: Understands natural-language queries entered directly into the natural-language field (e.g., `Ford F150. 6.5ft bed. XLT.`), automatically extracting canonical Make (`Ford`), Model (`F-150`, disambiguating `Bronco` vs. `Bronco Sport`, `F-150` vs. `F-150 Lightning`, `CX-5` vs. `CX-50`, `Cherokee` vs. `Grand Cherokee`), word-bounded Trim (`XLT` without false-matching `XL`), Bed Length (`6.5 ft Bed`), Cab Style, Engine/Powertrain, Year Range, Price/Mileage caps, Drivetrain, Condition, Color, and Package codes (`FX4`, `302A`, `Black Appearance`).
    - **DMS `BedLength` Facet + Build-Sheet Verification**: Queries `prestonmotor.com` Cosmos `BedLength` facets (`6-1/2' Box`, `5-1/2' Box`, `6 3/4' Box`, `8' Box`, etc.) alongside full dealer build-sheet comments so ONLY vehicles matching every parsed criterion are shown, accompanied by a live **Understood Search Criteria** chip preview in the UI.
11. **VIN Recall Check — Differentiating Complete vs. Incomplete Recalls (`VinRecallScreen` + `NhtsaRecallService`)**
    - **17-Character VIN Validation & Factory Decode**: Validates standard 17-character VINs (excluding `I`, `O`, `Q`) and decodes Model Year, Make, Model, Trim/Series, Body Class, Engine displacement/cylinders/turbo, Fuel/Electrification, Drivetrain, and Assembly Plant via official NHTSA vPIC (`vpic.nhtsa.dot.gov`).
    - **Per-VIN Complete vs. Incomplete Reconciliation + Gemini Analysis**: Combines NHTSA's recall taxonomy (`api.nhtsa.gov/recalls/recallsByVehicle`, extracting OEM campaign codes such as `25S53`) with live VIN-specific Open Recall lookup (`prestonmotor.com/autocheck.aspx`) and **Gemini (`gemini-2.5-flash`)** so every recall is classified as **Incomplete • Open Recall**, **Incomplete • Remedy Not Available**, or **Complete • Closed on VIN**, complete with KPI summary cards, `All` / `Incomplete` / `Complete` filter chips, and persistent `Mark Complete` / `Mark Incomplete` dealership service overrides.

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
