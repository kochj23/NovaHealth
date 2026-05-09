# NovaHealth

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-iOS%2016.0%2B-blue)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange)
![Tests](https://img.shields.io/badge/tests-99-brightgreen)
![Version](https://img.shields.io/badge/version-1.0.0-blue)

**iPhone HealthKit to Nova bridge.** Reads 17 health metrics from HealthKit and pushes them to Nova's local memory server on your Mac. All data stays on your local network — nothing touches the cloud.

Written by Jordan Koch.

---

## Architecture

```mermaid
graph TD
    subgraph iPhone
        Devices[Withings · Dexcom · Apple Watch] -->|HealthKit| App[NovaHealth App]
        App --> Pusher[HealthPusher]
        Pusher --> Daily[collectAndPush<br/>17 metrics · 6 AM daily]
        Pusher --> History[exportHistory<br/>5 years of daily aggregates]
    end

    Daily & History -->|HTTP POST over WiFi LAN| Receiver

    subgraph Mac["Mac Studio (192.168.1.6)"]
        Receiver[nova_healthkit_receiver.py :37450]
        Receiver --> Files[Daily JSON files<br/>~/.openclaw/private/health/]
        Receiver --> Memory[(pgvector Memory<br/>source=apple_health)]
        Memory --> Corr[nova_health_correlation.py<br/>weekly trend analysis]
        Corr --> Slack[Slack alerts]
    end
```

### Daily Push Flow

```mermaid
sequenceDiagram
    participant HealthKit
    participant Pusher as HealthPusher
    participant Recv as nova_healthkit_receiver.py
    participant PG as PostgreSQL

    Pusher->>HealthKit: Query 17 metric types
    HealthKit-->>Pusher: Latest values + daily sums
    Pusher->>Pusher: Round to 2dp, build JSON payload
    Pusher->>Recv: HTTP POST (WiFi LAN)
    Recv->>Recv: Write YYYY-MM-DD.json (0600 perms)
    Recv->>PG: INSERT with source=apple_health, privacy=local-only
    Note over PG: Excluded from cloud-routed LLM prompts
```

---

## Metrics

17 metric types from HealthKit:

| Metric | Unit | Sources |
|--------|------|---------|
| Heart Rate | bpm | Withings, Apple Watch |
| Resting Heart Rate | bpm | Apple Watch, Withings |
| Heart Rate Variability (SDNN) | ms | Apple Watch, Withings |
| Blood Pressure (systolic) | mmHg | Withings BPM Connect |
| Blood Pressure (diastolic) | mmHg | Withings BPM Connect |
| Blood Glucose | mg/dL | Dexcom G6/G7 |
| Weight | lbs | Withings Body+ |
| Body Fat | % | Withings Body+ |
| SpO2 | % | Withings, Apple Watch |
| Steps | count | iPhone, Apple Watch |
| Active Energy | kcal | iPhone, Apple Watch |
| Basal Energy | kcal | iPhone, Apple Watch |
| Distance (walking/running) | miles | iPhone, Apple Watch |
| Flights Climbed | count | iPhone |
| Body Temperature | °F | Withings Thermo |
| Respiratory Rate | /min | Apple Watch |
| Sleep | hours | Withings Sleep, Apple Watch |

---

## Features

**Daily Push** — Automatic background refresh at ~6 AM. Also available on-demand via Push Now.

**History Export** — One tap sends up to 5 years of daily aggregated data to Nova's memory server.

**Minimal UI** — Single screen: authorization status, last push time, latest values, two buttons.

---

## Requirements

- iPhone running iOS 16.0+
- Mac running Nova with `nova_healthkit_receiver.py` on port 37450
- Both devices on the same local network
- HealthKit data sources (Withings, Dexcom, Apple Watch, etc.)

---

## Installation

Sideloaded via Xcode — not on the App Store.

```bash
cd /Volumes/Data/xcode/NovaHealth
open NovaHealth.xcodeproj
# Connect iPhone, select device target, Cmd+R
```

**Mac-side receiver:**
```bash
python3 ~/.openclaw/scripts/nova_healthkit_receiver.py
# Listens on 0.0.0.0:37450 for incoming iPhone data
```

**Configuration** — set the Mac IP in `HealthPusher.swift`:
```swift
private let serverURL = "http://192.168.1.6:37450/health"
```

---

## Privacy

- All data stays on your local network — iPhone pushes directly to Mac over WiFi
- No cloud services, no third-party APIs
- Vector memories tagged `privacy: local-only` — excluded from all cloud-routed LLM prompts
- Health files stored with `0600` permissions
- Read-only HealthKit access — never writes to HealthKit

---

## Testing

99 tests covering unit, security, formatting, and integration.

```bash
xcodebuild -scheme NovaHealth -destination "generic/platform=iOS" test
```

| Category | Tests | Description |
|----------|-------|-------------|
| HealthPusher Core | 12 | Singleton, rounding, metric keys |
| ContentView Formatting | 19 | Key/value formatting for all 17 types, time-ago display |
| Security | 16 | Local URL only, no cloud, no PII, port range, timeout |
| HKUnit Extension | 1 | beatsPerMinute unit |
| Frame/Smoke | 51 | Comprehensive model path coverage |

---

## License

MIT License — Copyright 2026 Jordan Koch

See [LICENSE](LICENSE) for the full text.

Written by Jordan Koch ([@kochj23](https://github.com/kochj23))
