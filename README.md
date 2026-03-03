# P2P Wi-Fi Direct — NXP · Jetson Nano · RPi

Router-free, device-to-device Wi-Fi connection. Auto boot, watchdog, and smart power management.

---

## Supported Devices

| Device                         | Profile  | Wi-Fi Chip       | Interface | 5GHz           |
| ------------------------------ | -------- | ---------------- | --------- | -------------- |
| NXP i.MX8M (AzureWave 88W8997) | `nxp`    | Marvell 88W8997  | `mlan0`   | ✅             |
| Jetson Nano                    | `jetson` | Varies by module | `wlan0`   | ✅             |
| Raspberry Pi Zero / Zero 2W    | `rpi`    | BCM43438         | `wlan0`   | ❌ 2.4GHz only |
| Raspberry Pi 3B+               | `rpi3bp` | BCM43455         | `wlan0`   | ✅             |
| Raspberry Pi 4B                | `rpi4`   | BCM43455         | `wlan0`   | ✅             |
| Raspberry Pi 5                 | `rpi5`   | CYW43455         | `wlan0`   | ✅             |

Host and client can be any combination (nxp↔rpi, jetson↔rpi4, etc.).
For combinations involving RPi Zero / Zero 2W, both sides must use 2.4GHz.

---

## Architecture

```
HOST (mode=2 AP)  ←──────────────────→  CLIENT (mode=0 STA)
  wlan0 / mlan0                            wlan0
  192.168.77.1                             192.168.77.2
```

No P2P-GO, no virtual interfaces. Both sides connect directly over the physical interface.

---

## Setup

### Interactive (Recommended)

```bash
git clone <repo> && cd p2p-wifi-direct
sudo ./setup.sh
```

### With Arguments

```bash
sudo ./setup.sh --role host   --device nxp
sudo ./setup.sh --role client --device rpi
sudo ./setup.sh --role host   --device rpi4 --freq 2.4
sudo ./setup.sh --role host   --device nxp  --ssid MyNet --psk MyPass
```

### Uninstall

```bash
sudo ./setup.sh --uninstall
```

---

## Services

```
p2p-init.service      → Establishes the connection (AP/STA)
p2p-watchdog.service  → Monitors connection, restarts on failure
p2p-power.service     → Manages power mode automatically
```

```bash
# Start
systemctl start p2p-init.service
systemctl start p2p-watchdog.service
systemctl start p2p-power.service

# Logs
journalctl -fu p2p-init.service
journalctl -fu p2p-watchdog.service
journalctl -fu p2p-power.service

# Status
ls /run/p2p-connected        # file exists = connected
wpa_cli -i wlan0 status
```

---

## Power Management

`p2p-power.service` monitors TX traffic and switches modes automatically. No external intervention needed.

| TX Rate           | Mode            | Effect                                           |
| ----------------- | --------------- | ------------------------------------------------ |
| > 100 KB/s        | **Performance** | power save OFF, `pfifo_fast` queue (low latency) |
| < 10 KB/s for 30s | **Efficient**   | power save ON                                    |

### Driver-Aware Power Save

| Device                       | Interface | Command                              |
| ---------------------------- | --------- | ------------------------------------ |
| NXP i.MX8M (Marvell 88W8997) | `mlan0`   | `mlanutl mlan0 pscfg 0/1`            |
| RPi (brcmfmac)               | `wlan0`   | `iwconfig wlan0 power on/off`        |
| Jetson (cfg80211)            | `wlan0`   | `iw dev wlan0 set power_save on/off` |

### Optional Override

Can be called from a camera application or bash:

```bash
# Bash
p2p-power force-performance
p2p-power force-efficient
p2p-power auto               # return to auto mode

# Python / C / any language
echo "force-performance" > /run/p2p-power.cmd
```

---

## U-Boot (NXP Only)

Change role and frequency without reflashing:

```bash
# U-Boot shell:
setenv node_role host
setenv p2p_iface mlan0
setenv p2p_channel 44
setenv p2p_freq 5220
setenv p2p_reg_class 115
saveenv
```

Verify:

```bash
fw_printenv node_role p2p_iface p2p_channel p2p_freq p2p_reg_class
```

**Priority order:** U-Boot env → `/etc/default/video-node` → script default

---

## Connection Architecture

### How It Works

- **Host (AP)** does **not** scan. It broadcasts beacon frames and waits.
- **Client (STA)** scans → finds AP → connects.
- `/run/p2p-connected` is the shared state file: created by `p2p-init`, read by watchdog and power manager.

### Service Flow

```
System boot
    ↓
p2p-init     → bring up AP (host) or connect to AP (client)
               create /run/p2p-connected
    ↓
p2p-power    → start in EFFICIENT mode (power save ON)
    ↓
p2p-watchdog → ping other side every N seconds
    ↓
Stream starts  → TX > 100 KB/s  → switch to PERFORMANCE
Stream stops   → 30s idle       → switch back to EFFICIENT
Link lost      → watchdog       → restart p2p-init
```

### IP Table

| Role   | IP           | Watchdog Ping Target |
| ------ | ------------ | -------------------- |
| HOST   | 192.168.77.1 | 192.168.77.2         |
| CLIENT | 192.168.77.2 | 192.168.77.1         |

---

## wpa_supplicant Configuration

Both host and client use `wpa_supplicant` — no `hostapd`, no virtual interfaces.

| Parameter          | Value             | Description                      |
| ------------------ | ----------------- | -------------------------------- |
| `mode=2`           | Host              | AP mode                          |
| `mode=0`           | Client            | STA mode                         |
| `p2p_disabled=1`   | Both              | No P2P overhead                  |
| `proto=RSN`        | Both              | WPA2                             |
| `pairwise=CCMP`    | Both              | AES-CCMP encryption              |
| `key_mgmt=WPA-PSK` | Both              | Pre-Shared Key                   |
| `country=TR`       | Both              | Required for 5GHz channel access |
| `frequency=5220`   | Host (Jetson/NXP) | Channel 44, Non-DFS, safe 5GHz   |

### 5GHz Channel Selection

- **Non-DFS (safe) channels:** 36, 40, **44** ✅, 48
- **DFS channels (52–140):** require radar detection — may delay AP startup
- This project uses **Channel 44 (5220 MHz)** — optimal choice

### Security: WPA2-PSK

Closed device-to-device link with physical proximity. WPA2-PSK is sufficient.

|                           | WPA2-PSK (current) | WPA3-SAE            |
| ------------------------- | ------------------ | ------------------- |
| Offline dictionary attack | ⚠️ possible        | ✅ not possible     |
| Forward Secrecy           | ❌                 | ✅                  |
| Hardware support          | ✅ universal       | ⚠️ newer chips only |

---

## File Structure

```
p2p-wifi-direct/
├── setup.sh
├── config/
│   ├── video-node.env.template
│   ├── p2p-host.conf
│   └── p2p-client.conf
├── scripts/
│   ├── p2p-init.sh        ← Establishes connection
│   ├── p2p-watchdog.sh    ← Monitors connection
│   └── p2p-power.sh       ← Power manager (closed box)
├── systemd/
│   ├── p2p-init.service
│   ├── p2p-watchdog.service
│   └── p2p-power.service
└── device-profiles/
    ├── nxp.env
    ├── jetson.env
    ├── rpi.env
    ├── rpi3bp.env
    ├── rpi4.env
    └── rpi5.env
```

---

## Troubleshooting

```bash
# List interfaces
iw dev

# Check AP/STA mode support
iw phy | grep -A10 "Supported interface modes"

# wpa_supplicant log
tail -f /var/log/wpa_supplicant.log

# Manual connection test
wpa_cli -i wlan0 status
ping -I wlan0 192.168.77.1
```
