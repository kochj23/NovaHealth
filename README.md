# NovaHealth

**iPhone HealthKit → Nova bridge.** Reads health metrics from HealthKit and pushes them to Nova's local memory server on your Mac. All data stays on your local network — nothing touches the cloud.

Written by Jordan Koch.

## What It Does

NovaHealth is a minimal iOS app that silently bridges Apple HealthKit to [Nova](https://github.com/kochj23/nova), a local AI familiar running on a Mac Studio. It collects health data from connected devices and sends it to Nova's vector memory for trend analysis and correlation with calendar, email, and activity data.

```
┌──────────────┐     HealthKit     ┌──────────────┐     HTTP POST      ┌──────────────┐
│   Withings   │──────────────────▶│              │────────────────────▶│              │
│   Dexcom     │    (on-device)    │  NovaHealth  │   (WiFi, LAN)      │   Nova Mac   │
│   RingCon    │──────────────────▶│   (iPhone)   │────────────────────▶│  :37450      │
│   23andMe    │                   │              │                     │              │
│   Brightside │──────────────────▶│              │     JSON payload    │  pgvector    │
└──────────────┘                   └──────────────┘                     └──────────────┘
```

## Metrics Collected

NovaHealth reads **17 metric types** from HealthKit, supporting data from multiple sources:

| Metric | Unit | Sources |
|--------|------|---------|
| Heart Rate | bpm | Withings scale, Withings BPM |
| Resting Heart Rate | bpm | Apple Watch, Withings |
| Heart Rate Variability (SDNN) | ms | Apple Watch, Withings |
| Blood Pressure (systolic) | mmHg | Withings BPM Connect |
| Blood Pressure (diastolic) | mmHg | Withings BPM Connect |
| Blood Glucose | mg/dL | Dexcom G6, Dexcom G7 |
| Weight | lbs | Withings Body+ scale |
| Body Fat | % | Withings Body+ scale |
| SpO2 | % | Withings, Apple Watch |
| Steps | count | iPhone, Apple Watch |
| Active Energy | kcal | iPhone, Apple Watch |
| Basal Energy | kcal | iPhone, Apple Watch |
| Distance (walking/running) | miles | iPhone, Apple Watch |
| Flights Climbed | count | iPhone |
| Body Temperature | °F | Withings Thermo |
| Respiratory Rate | /min | Apple Watch |
| Sleep | hours | Withings Sleep, Apple Watch |

### Data Coverage (as of April 2026)

| Metric | Days of History | Coverage |
|--------|----------------|----------|
| Steps | 1,826 | 100% (5 years) |
| Heart Rate | 984 | 54% |
| Active Energy | 496 | 27% |
| HRV | 101 | 6% |
| Resting HR | 72 | 4% |

## Features

### Daily Push
Automatic background refresh at ~6:00 AM pushes today's health snapshot to Nova. Also available on-demand via the **Push Now** button.

### History Export
One-tap **Export History** button sends up to 5 years of daily aggregated health data to Nova's memory server. Each metric type is exported sequentially, grouped by day, with sample counts. Runs once — subsequent pushes are daily snapshots.

### Minimal UI
Single screen showing:
- HealthKit authorization status
- Last push time
- Metric count
- Latest data values with formatted units
- Push Now and Export History buttons

No tracking. No analytics. No accounts.

## Architecture

```
NovaHealthApp.swift          — App entry point, BGTaskScheduler registration
├── AppDelegate              — Background refresh scheduling (6am daily)
├── ContentView.swift        — SwiftUI status screen
└── HealthPusher.swift       — HealthKit queries + HTTP push logic
    ├── collectAndPush()     — Daily: 17 metric snapshot
    ├── exportHistory()      — Bulk: 5-year daily aggregates
    ├── fetchLatest()        — Most recent sample (7-day lookback)
    ├── fetchTodaySum()      — Cumulative sum for today
    └── fetchAllSamples()    — Full history query for bulk export
```

### Data Flow

1. **HealthKit** → on-device queries (no network)
2. **NovaHealth** → JSON payload over local WiFi
3. **nova_healthkit_receiver.py** (Mac, port 37450) → stores daily JSON files
4. **Nova Memory Server** (Mac, port 18790) → vector embeddings in PostgreSQL+pgvector
5. **nova_health_correlation.py** → weekly/monthly trend analysis
6. **Slack #nova-notifications** → pattern alerts

### Receiver (Mac-side)

The companion script `nova_healthkit_receiver.py` runs on the Mac:

```bash
# Start receiver (listens on 0.0.0.0:37450 for iPhone WiFi access)
python3 ~/.openclaw/scripts/nova_healthkit_receiver.py
```

- Stores daily JSON files at `~/.openclaw/private/health/YYYY-MM-DD.json`
- Ingests into Nova's vector memory with `source: "apple_health"`, `privacy: "local-only"`
- Handles both daily snapshots and history bulk exports
- Merges metrics from multiple pushes for the same day

## Privacy

- **All data stays on your local network.** The iPhone pushes directly to your Mac's IP over WiFi.
- **No cloud services involved.** No Apple Health sharing, no third-party APIs, no analytics.
- **Vector memories tagged `privacy: local-only`.** Nova's intent router excludes them from cloud-routed LLM prompts.
- **Health files stored with 0600 permissions.** Only your user account can read them.
- **No HealthKit write access.** The app requests read-only permissions.

## Requirements

- iPhone running iOS 16.0+
- Mac running Nova with `nova_healthkit_receiver.py` active on port 37450
- Both devices on the same local network
- HealthKit data sources (Withings, Dexcom, Apple Watch, etc.)

## Installation

NovaHealth is sideloaded via Xcode — not distributed through the App Store.

```bash
cd /Volumes/Data/xcode/NovaHealth

# Generate Xcode project
xcodegen generate

# Build for device
xcodebuild -scheme NovaHealth -sdk iphoneos -allowProvisioningUpdates build

# Deploy to connected iPhone
xcrun devicectl device install app \
  --device "DEVICE_UUID" \
  "$(find ~/Library/Developer/Xcode/DerivedData/NovaHealth*/Build/Products/Debug-iphoneos -name 'NovaHealth.app')"

# Launch
xcrun devicectl device process launch --device "DEVICE_UUID" net.digitalnoise.NovaHealth
```

On first launch, grant HealthKit access to all requested categories.

## Configuration

The Mac's IP address is set in `HealthPusher.swift`:

```swift
private let serverURL = "http://192.168.1.6:37450/health"
```

Update this if your Mac's local IP changes. A future version may use Bonjour/mDNS for automatic discovery.

## Integration with Nova

Once data flows, Nova can:

- **Correlate health with calendar:** "Your resting HR is 8bpm higher on days with 4+ meetings"
- **Track glucose patterns:** "Blood glucose spikes to 160+ on days you skip lunch"
- **Monitor long-term trends:** "Weight down 3 lbs this month, BP stable, HRV improving"
- **Proactive alerts:** "Sleep has been below 6h for 3 consecutive nights"

Run the correlation analysis manually:

```bash
python3 ~/.openclaw/scripts/nova_health_correlation.py --weekly
python3 ~/.openclaw/scripts/nova_health_correlation.py --monthly
```

## Project Structure

```
NovaHealth/
├── NovaHealth.xcodeproj/       # Xcode project (generated by xcodegen)
├── NovaHealth/
│   ├── NovaHealthApp.swift     # App entry + background task registration
│   ├── ContentView.swift       # SwiftUI UI
│   ├── HealthPusher.swift      # HealthKit queries + HTTP push
│   ├── Info.plist              # HealthKit usage description, background modes
│   └── NovaHealth.entitlements # HealthKit capability
├── project.yml                 # xcodegen spec
└── README.md
```

## License

MIT License — Copyright (c) 2026 Jordan Koch

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
