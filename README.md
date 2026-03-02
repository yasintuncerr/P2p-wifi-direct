# P2P Wi-Fi Direct — NXP · Jetson Nano · RPi Zero 2W

Creates Wi-Fi Direct(P2P) connection between two linux devices without any Router. Includes Automated boot, persistent group, and wathcdog.

---

## Suppoerted Devices

| Device | Profile | Wi-Fi Chip | Interface | 5GHz |
|---|---|---|---|---|
| NXP i.MX8M (AzureWave 88W8997) | `nxp` | Marvell 88W8997 | `mlan0` | ✅ |
| Jetson Nano | `jetson` | Modüle göre değişir | `wlan0` | ✅ |
| Raspberry Pi Zero / Zero 2W | `rpi` | BCM43438 | `wlan0` | ❌ Only 2.4GHz |
| Raspberry Pi 3B+ | `rpi3bp` | BCM43455 | `wlan0` | ✅ |
| Raspberry Pi 4B | `rpi4` | BCM43455 | `wlan0` | ✅ |
| Raspberry Pi 5 | `rpi5` | CYW43455 | `wlan0` | ✅ |

---

## Test Scenario


```
Scenario 1:  NXP (client) ──── Jetson Nano (host)    → 5GHz
Scenario 2:  NXP (host)   ──── RPi Zero 2W (client)  → 2.4GHz
Scenario 3:  NXP (host)   ──── NXP (client)           → 5GHz
```

> **Important** both 2 device should set 2.4GHz for Scenario 2
> RPI Zero 2W doesn't have any 5GHz radio.

---


## Setup

### Interactive (Suggested)

```bash
git clone && cd p2p-wifi-direct
sudo ./setup.sh
````

It asks questions step by step: role, device, scenario, SSID, password.

### With arguments(for script/CI)
```bash
# Install Nxp as the host
sudo ./setuo.sh --role host --device nxp

# Install RPI Zero/Zero 2W as the client (2.4GHz)
sudo ./setup.sh --role client --device rpi

# Install RPI 3B+ as client
sudo ./setup.sh --role client --device rpi3bp

...

```


### Uninstall
```bash
sudo ./setup.sh --uninstall
```

---

## U-Boot Env (Only for NXP)
No need reflash for change role and frequency:

```bash
#U-Boot shell:
setenv node-role host
setenv p2p_iface mlan0
setenv p2p_channel 44
setevn p2p_freq 5220
setenv p2p_reg_class 115
saveenv
```


For Check:
```bash
fw_printenv node_role p2p_iface p2p_channel
````

U-boot env is **always** overrides `/etc/default/video-node`file

---


## Priority Order


```
U-Boot env  →  /etc/default/video-node  →  script default
 (win)         (fallback)                    (last ditch)
```

---

## File Structure


```
p2p-wifi-direct/
├── setup.sh                    ← Main setup script
├── config/
│   ├── video-node.env.template ← /etc/default/video-node schema
│   ├── p2p-host.conf           ← wpa_supplicant HOST config
│   └── p2p-client.conf         ← wpa_supplicant CLIENT config
├── scripts/
│   ├── p2p-init.sh             ← Initiating connection
│   └── p2p-watchdog.sh         ← Reconnecting after disconnection
├── systemd/
│   ├── p2p-init.service
│   └── p2p-watchdog.service
└── device-profiles/
    ├── nxp.env                 ← NXP parameters
    ├── jetson.env              ← Jetson parameters
    └── rpi.env                 ← RPi parameters (2.4GHz)
```

---

## Service Management


```bash
# Start
systemctl start p2p-init.service
systemctl start p2p-watchdog.service

# watch log
journalctl -fu p2p-init.service
journalctl -fu p2p-watchdog.service

# Connection status
ls /run/p2p-connected      # if there is a file → connected
wpa_cli -i mlan0 status    # detailed status (for nxp)

# Restart
systemctl restart p2p-init.service
```

---


## Scenario IP Table

| Role | IP | Ping Target (watchdog) |
|---|---|---|
| HOST | 192.168.77.1 | 192.168.77.2 |
| CLIENT | 192.168.77.2 | 192.168.77.1 |

---

## Troubleshooting

**Find Interface:**
```bash
iw dev
```

**Check P2P support:**
```bash
iw phy | grep -A10 "Supported interface modes"
# P2P-client and P2P-GO should appear
```

**Read the wpa_supplicant log:**
```bash
tail -f /var/log/wpa_supplicant.log
```

**Manual connection test:**
```bash
# HOST'ta:
wpa_cli -i mlan0 p2p_group_add persistent freq=5220

# CLIENT'ta:
wpa_cli -i wlan0 p2p_find
wpa_cli -i wlan0 p2p_peers
```