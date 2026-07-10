# Response `dataSize` Correlation Policy

**Status: unconfirmed on physical Razer Viper V3 HyperSpeed (`1532:00B8`).**

## Current policy (code)

`RazerResponseValidator` requires `response.dataSize == request.dataSize` **only for successful** (`0x02`) responses. Busy, not-supported, timeout, failure, and blocked-device statuses do not require a matching `dataSize`, because error replies may not echo the request size.

Unit tests currently manufacture responses from requests, so they prove the chosen policy, not device behavior.

## Required before treating as hardware-compatible

Capture and check in fixtures under `docs/testing/device-fixtures/` (hex dumps of full 90-byte reports, no private data beyond protocol fields):

| Command | Request `dataSize` | Observe response `dataSize` on success | Observe on not-supported / failure if reachable |
|---------|-------------------|----------------------------------------|--------------------------------------------------|
| Battery (`07:80`) | `0x02` | | |
| Charging (`07:84`) | `0x02` | | |
| DPI get (`04:85`) | `0x07` | | |
| DPI stages get (`04:86`) | `0x26` | | |
| Polling get (`00:85`) | `0x01` | | |
| Wheel probe (`02:94`, `02:96`, `02:97`) | `0x02` | | |

CLI helpers:

```bash
./RazerProbeCLI battery
./RazerProbeCLI dpi
./RazerProbeCLI stages
./RazerProbeCLI polling
./RazerProbeCLI wheel-probe
```

If a successful reply returns a larger known payload than the request, document an explicit minimum in `RazerResponseValidator.validateDataSize` instead of exact equality for that command.

## Fixture layout (when captured)

```
docs/testing/device-fixtures/
  README.md                 # macOS version, firmware/dongle IDs, capture date
  battery-success.hex
  dpi-success.hex
  dpi-stages-success.hex
  polling-success.hex
  scroll-mode-*.hex         # success and/or not-supported
```

Do not commit secrets or personally identifying HID captures beyond the 90-byte feature reports needed for correlation tests.
