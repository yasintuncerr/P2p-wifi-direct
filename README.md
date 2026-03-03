# P2P Wi-Fi Direct — NXP · Jetson Nano · RPi

Router-free, device-to-device Wi-Fi connection. Auto boot, watchdog, and smart power management.

---

## Supported Devices

| Device | Profile | Wi-Fi Chip | Interface | 5GHz |
|---|---|---|---|---|
| NXP i.MX8M (AzureWave 88W8997) | `nxp` | Marvell 88W8997 | `mlan0` | ✅ |
| Jetson Nano | `jetson` | Varies by module | `wlan0` | ✅ |
| Raspberry Pi Zero / Zero 2W | `rpi` | BCM43438 | `wlan0` | ❌ 2.4GHz only |
| Raspberry Pi 3B+ | `rpi3bp` | BCM43455 | `wlan0` | ✅ |
| Raspberry Pi 4B | `rpi4` | BCM43455 | `wlan0` | ✅ |
| Raspberry Pi 5 | `rpi5` | CYW43455 | `wlan0` | ✅ |

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

`p2p-power.service` runs as a closed box — no external intervention needed.

| TX Rate | Mode |
|---|---|
| > 100 KB/s | **Performance** — power save off, low latency |
| < 10 KB/s for 30s | **Efficient** — power save on |

### Optional Override
Can be called from a camera application or bash:

```bash
# Bash
p2p-power force-performance
p2p-power force-efficient
p2p-power auto               # return to closed box mode

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

## IP Table

| Role | IP | Watchdog Ping Target |
|---|---|---|
| HOST | 192.168.77.1 | 192.168.77.2 |
| CLIENT | 192.168.77.2 | 192.168.77.1 |

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