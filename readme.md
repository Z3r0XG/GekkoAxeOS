![GitHub Downloads (all assets, all releases)](https://img.shields.io/github/downloads/Z3r0XG/GekkoAxeOS/total)
![GitHub Release](https://img.shields.io/github/v/release/Z3r0XG/GekkoAxeOS)
![GitHub commit activity](https://img.shields.io/github/commit-activity/t/Z3r0XG/GekkoAxeOS)

# GekkoAxeOS

> ## ⚠️ Disclaimer
>
> **GekkoAxeOS is a community firmware for the GekkoAxe hardware — it is not produced or supported by [GekkоScience](https://www.gekkoscience.com).**
>
> - "GekkoAxe" refers to the [open-source hardware](https://github.com/sidehack-gekko/GekkoAxe) by GekkоScience
> - Provided **AS-IS**, with no warranty — flashing third-party firmware may void your warranty and could damage hardware if used incorrectly
> - Use at your own risk

GekkoAxeOS is open-source ESP32-S3 firmware for the **[GekkoAxe GT](https://github.com/sidehack-gekko/GekkoAxe)** — a dual BM1370 Bitcoin miner by [GekkоScience](https://www.gekkoscience.com), built on the Bitaxe platform. It is a fork of [bitaxeorg/ESP-Miner](https://github.com/bitaxeorg/ESP-Miner), tracking upstream closely and adding GekkoAxe GT-specific support and UI improvements.

For pre-built images ready to flash, see the [latest release](https://github.com/Z3r0XG/GekkoAxeOS/releases/latest).

---

## Hardware: GekkoAxe GT

| Parameter | Value |
|---|---|
| Board version | `800` |
| ASICs | 2× BM1370 |
| Device family | `gammaturbo` |
| Voltage regulator | TPS546 |
| Fan controller | EMC2103 |
| MCU | ESP32-S3-WROOM-1 N16R8 (16 MB Flash, 8 MB Octal SPI PSRAM) |
| Default ASIC frequency | 600 MHz |
| Default ASIC voltage | 1100 mV |

---

## Changes vs upstream ESP-Miner

- **Board `800` support** — `device_config.h` entry for GekkoAxe GT (`gammaturbo`, EMC2103, TPS546, `temp_offset = -10`, `power_consumption_target = 12 W`)
- **Share Diff chart** — new "Share Diff" option in the home chart dropdown, tracking actually-submitted share difficulty over time from the statistics ring buffer, with a matching live data feed (`lastSubmittedDiff`) in `/api/system/info`
- **OTA updates point to this repo** — the in-UI update checker and OTA download resolve releases from `Z3r0XG/GekkoAxeOS` instead of `bitaxeorg/ESP-Miner`
- **Renamed OTA file validation** — firmware OTA expects `GekkoAxeOS-*-firmware.bin`; web OTA expects `GekkoAxeOS-*-www.bin`
- **GekkoAxeOS branding** — page title, topbar logo replaced with GekkoAxeOS SVG wordmark
- **`build_release.sh`** — packages three release artifacts automatically: factory image (full 16 MB merge), firmware-only `.bin`, and www-only `.bin`, with the GekkoAxe GT NVS config baked in

---

## Flashing a release

### Factory flash (first-time or full reset)

The factory image contains the bootloader, partition table, firmware, web UI, and the GekkoAxe GT NVS config all merged into a single file. Flash it at address `0x0`.

**Option A — esptool-js (browser, no install required)**

1. Power the GekkoAxe GT via barrel connector and connect USB to your computer
2. Open [esptool-js](https://espressif.github.io/esptool-js/) in Chrome
3. Set baud rate to `921600`, click **Connect**, select the serial port
4. Set Flash Address to `0x0`
5. Choose the factory image: `GekkoAxeOS-{VERSION}-factory.bin`
6. Click **Program** and wait for "Leaving..."
7. Press **RESET** on the device once complete

**Option B — bitaxetool (command line)**

> bitaxetool v0.6.1 is required (locked to esptool v4.9.0). esptool v5.x is not compatible.

```bash
pip install bitaxetool==0.6.1

# Flash factory image with GekkoAxe GT config
bitaxetool --config ./config-GekkoAxe_GT.cvs --firmware ./GekkoAxeOS-{VERSION}-factory.bin
```

**Option C — esptool directly**

```bash
esptool.py --chip esp32s3 -b 921600 --before default_reset --after hard_reset \
  write_flash --flash_mode dio --flash_size 16MB --flash_freq 80m \
  0x0 GekkoAxeOS-{VERSION}-factory.bin
```

### OTA update (device already running GekkoAxeOS)

Navigate to your device's web UI → **Settings** → **Updates**.

- **Firmware update**: upload `GekkoAxeOS-{VERSION}-firmware.bin`
- **Web UI update**: upload `GekkoAxeOS-{VERSION}-www.bin`

The in-UI update checker automatically compares against the latest release on this repository.

---

## Administration

Once the device is connected to Wi-Fi, the web UI is accessible at:

- `http://<device-ip>` — main UI
- `http://GekkoAxe` — mDNS alias (if your router supports it)
- `http://<device-ip>/recovery` — recovery page if the main UI is inaccessible (e.g. after a failed www update)

### Unlock overclocking settings

Append `?oc` to the Settings tab URL to unlock ASIC frequency and core voltage fields. Use with adequate cooling — overclocking without it can damage the hardware.

---

## GekkoAxeOS API

The web server on port 80 exposes a REST API. Full spec: [`main/http_server/openapi.yaml`](./main/http_server/openapi.yaml).

**GET**
- `/api/system/info` — system information (hashrate, temps, uptime, pool, `lastSubmittedDiff`, etc.)
- `/api/system/asic` — ASIC settings
- `/api/system/statistics?columns=...` — historical stats ring buffer (720 entries)
- `/api/system/statistics/dashboard` — dashboard stats
- `/api/system/wifi/scan` — available Wi-Fi networks

**POST**
- `/api/system/restart` — restart the device
- `/api/system/identify` — flash LEDs / beep
- `/api/system/OTA` — upload firmware binary
- `/api/system/OTAWWW` — upload web UI binary

**PATCH**
- `/api/system` — update settings (pool, Wi-Fi, fan speed, voltage, frequency, etc.)

```bash
# Current system info
curl http://<device-ip>/api/system/info

# Last submitted share difficulty
curl http://<device-ip>/api/system/info | python3 -m json.tool | grep lastSubmittedDiff

# Update fan speed
curl -X PATCH http://<device-ip>/api/system \
     -H "Content-Type: application/json" \
     -d '{"fanspeed": 80}'

# OTA firmware update
curl -X POST \
     -H "Content-Type: application/octet-stream" \
     --data-binary "@GekkoAxeOS-{VERSION}-firmware.bin" \
     http://<device-ip>/api/system/OTA
```

---

## Building from source

### Prerequisites

- [ESP-IDF v5.5](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32s3/get-started/) targeting `esp32s3`
- Node.js ≥ 22 and npm (for the Angular web UI)
- Linux or macOS recommended

### Quick setup

```bash
# Clone this repo
git clone https://github.com/Z3r0XG/GekkoAxeOS.git
cd GekkoAxeOS

# Install ESP-IDF v5.5
git clone --branch v5.5 --depth 1 --recursive https://github.com/espressif/esp-idf.git ~/esp/idf
~/esp/idf/install.sh esp32s3
```

### Build

```bash
bash build_release.sh
```

This sources ESP-IDF, builds the full firmware + Angular web UI, and produces three artifacts in `releases/{VERSION}/`:

| File | Use |
|---|---|
| `GekkoAxeOS-{VERSION}-factory.bin` | Full 16 MB factory image, flash at `0x0` |
| `GekkoAxeOS-{VERSION}-firmware.bin` | Firmware only, for OTA Firmware update |
| `GekkoAxeOS-{VERSION}-www.bin` | Web UI only, for OTA Web update |
| `config-GekkoAxe_GT.cvs` | NVS config used to build the factory image |

To skip the ESP-IDF build and re-package only (after a web UI change):

```bash
bash build_release.sh --no-build
```

### VSCode

Open the repository in VSCode with the [ESP-IDF extension](https://marketplace.visualstudio.com/items?itemName=espressif.esp-idf-extension). The `.vscode/settings.json` is pre-configured for ESP32-S3.

---

## Wi-Fi compatibility note

Some routers block outbound stratum connections — ASUS and certain TP-Link routers are known to do this. If mining doesn't start, try a different router or check firewall settings.

---

## Credits

GekkoAxeOS is built on [ESP-Miner](https://github.com/bitaxeorg/ESP-Miner) by the Bitaxe community. All upstream contributors retain their credit — this fork adds GekkoAxe GT hardware support and UI features on top of their work.
If you find that your not able to mine / have no hash rate you will need to check the Wi-Fi routers settings and disable the following;

1/ AiProtection

2/ IoT 

If your Wi-Fi router has both of these options you might have to disable them both.

If your still having problems here, check other settings within the Wi-Fi router and the bitaxe device, this includes the URL for
the Stratum Host and Stratum Port.

## Attributions

The display font is Portfolio 6x8 from https://int10h.org/oldschool-pc-fonts/ by VileR.
