# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | Yes                |

## Reporting a Vulnerability

If you discover a security vulnerability in NovaHealth, please report it responsibly.

**Contact:** Open a GitHub issue with the label `security` or email the repository owner.

**Response Time:** Security issues will be triaged within 48 hours.

## Security Features

- **Local network only** — Health data is never sent to cloud services
- **RFC 1918 validation** — Push target must be a private network address (10.x, 172.16-31.x, 192.168.x, or 127.x)
- **Read-only HealthKit** — NovaHealth never writes to HealthKit
- **No PII in payload** — Only anonymized metric keys (heart_rate, steps, etc.)
- **No authentication tokens in URLs** — Clean HTTP POST with JSON body
- **File permissions** — Receiver stores data with 0600 (owner-only) permissions
- **No analytics or tracking** — Zero telemetry, zero third-party SDKs

## Architecture Security

NovaHealth follows a strict local-only data flow:

1. iPhone reads HealthKit data
2. Data is pushed over WiFi LAN to Mac (HTTP POST)
3. Mac stores data in local PostgreSQL with pgvector
4. No data ever leaves the local network

## Dependencies

NovaHealth has zero third-party dependencies. It uses only:
- Apple HealthKit framework
- Foundation/SwiftUI (Apple standard libraries)
