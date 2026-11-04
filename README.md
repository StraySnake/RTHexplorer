# RTHexplorer

Send SMS and check the status of a **Huawei 4G/LTE router** from the command line — using only the router's local web API.

- **No cloud, no app, no extra software on the router**: it talks to the same local API as the router's web page.
- **Two commands**: `send` an SMS, or check the router `status` (login, SIM card, mobile network, signal) **without sending anything**.
- **Script-friendly**: one machine-readable result line on stdout, progress on stderr, meaningful exit codes.
- **Lightweight**: a single Bash script, in two flavours (with or without Python). Works on Raspberry Pi, NAS, Docker/Alpine containers, any Linux or macOS machine on the router's network.

Typical uses: alerts from security cameras or home automation, server monitoring, backup reports, door sensors, cron jobs… anything that can run a shell command.

---

## Contents

- [Two versions](#two-versions)
- [Requirements](#requirements)
- [Installation](#installation)
- [Configuration](#configuration)
- [Usage](#usage)
- [Output and exit codes](#output-and-exit-codes)
- [Examples](#examples)
- [Compatibility](#compatibility)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)
- [How it works](#how-it-works)
- [License](#license)

---

## Two versions

Both scripts have **the same commands, the same configuration and the same output**. Pick the one that matches the tools available on your machine:

| Script | Uses | Best for |
|---|---|---|
| `rthexplorer.sh` | `python3` (standard library only) | Most systems, Docker images that ship Python |
| `rthexplorer_bash.sh` | `openssl` + `base64` + `sed` — **no Python** | Minimal systems without Python: routers, NAS, small containers |

Everything below applies to both; just replace the script name.

## Requirements

- A Huawei 4G/LTE router with a SIM card that can send SMS
- A machine on the same network as the router, with `bash`, `curl`, `awk`, `mktemp`, and:
  - for `rthexplorer.sh`: `python3`
  - for `rthexplorer_bash.sh`: `openssl` (3.0+ for SCRAM devices), `base64`, `sed`, `tr`, `od`

Neither script needs the GNU-only `grep -P`, so both run on BusyBox-based systems.

## Installation

```bash
git clone https://github.com/StraySnake/RTHexplorer.git
cd RTHexplorer
chmod +x rthexplorer.sh rthexplorer_bash.sh
cp rthexplorer.conf.example rthexplorer.conf
chmod 600 rthexplorer.conf
```

Then edit `rthexplorer.conf` (see below) and check that everything works:

```bash
./rthexplorer.sh status        # or: ./rthexplorer_bash.sh status
```

Both scripts read the same `rthexplorer.conf`.

## Configuration

Settings are read from a config file and/or environment variables. **Environment variables take precedence.**

| Setting | Default | Description |
|---|---|---|
| `HUAWEI_ROUTER_URL` | `https://192.168.8.1` | Router web address. Use `http://…` if your router has no HTTPS. |
| `HUAWEI_USERNAME` | `admin` | Router administrator account |
| `HUAWEI_PASSWORD` | *(required)* | Router administrator password |
| `HUAWEI_CONFIG` | `rthexplorer.conf` next to the script | Path of the config file |

### Config file

`rthexplorer.conf` contains plain `KEY=VALUE` lines (quotes optional, `#` for comments). It is **read, never executed**.

```ini
HUAWEI_ROUTER_URL=https://192.168.8.1
HUAWEI_USERNAME=admin
HUAWEI_PASSWORD="my router password"
```

### Environment variables

```bash
HUAWEI_PASSWORD='my router password' ./rthexplorer.sh status
```

## Usage

```text
rthexplorer.sh send <phone_number> <message>   Send an SMS
rthexplorer.sh status                          Check the router (no SMS sent)
rthexplorer.sh help                            Show help
```

A short form is also accepted for compatibility: `rthexplorer.sh <phone_number> <message>`.

Use international phone numbers, e.g. `+33612345678`.

### Send an SMS

```bash
./rthexplorer.sh send +33612345678 "Front door opened at $(date +%H:%M)"
```

### Check the router without sending anything

```bash
./rthexplorer.sh status
```

It logs in, reads the SIM card state, the mobile network and the signal strength, then logs out. Ideal for a daily health check: you learn that SMS alerts are broken **before** you need them.

## Output and exit codes

Progress messages are written to **stderr**:

```text
[INFO] Connecting to https://192.168.8.1...
[OK] Session opened
[OK] Logged in as admin
[INFO] Sending SMS to +33612345678...
[OK] SMS accepted by the router
```

Exactly **one result line** is written to **stdout**, easy to parse:

| Situation | stdout |
|---|---|
| SMS sent | `STATUS=OK;SMS=sent` |
| Router healthy | `STATUS=OK;SIGNAL=4/5;OPERATOR=Orange F` |
| Any problem | `STATUS=ERROR;DETAIL=<reason>` |

Examples of `DETAIL`:

- `router unreachable at https://192.168.8.1 (powered off, cable, network?)`
- `login refused: wrong username or password (code 108006)`
- `login refused: too many attempts, try again later (code 108007)`
- `SIM card missing, locked or waiting for PIN (SimStatus=0)`
- `no mobile network (signal 0/5)`
- `SMS refused by the router (code …)`

| Exit code | Meaning |
|---|---|
| `0` | Success |
| `1` | Failure (see `DETAIL`) |
| `2` | Wrong usage (missing arguments) |

> "SMS accepted by the router" means the router queued the message. As with any SMS, delivery to the phone depends on the mobile network.

## Examples

**Daily health check with cron** (alert by e-mail if the router is not ready):

```cron
0 9 * * * /opt/RTHexplorer/rthexplorer.sh status >/dev/null 2>&1 || echo "SMS router not ready" | mail -s "SMS alert" you@example.com
```

**Use the result in a script:**

```bash
result="$(./rthexplorer.sh status 2>/dev/null)"
if [[ "$result" == STATUS=OK* ]]; then
    echo "Router ready: ${result#STATUS=OK;}"
else
    echo "Problem: ${result#*DETAIL=}"
fi
```

**Notify several people:**

```bash
for number in +33611111111 +33622222222; do
    ./rthexplorer.sh send "$number" "Backup finished"
done
```

**Home automation** (example: a Home Assistant `shell_command`):

```yaml
shell_command:
  send_sms: >-
    bash /config/scripts/rthexplorer.sh send {{ number | to_json }} {{ message | to_json }}
  sms_router_status: bash /config/scripts/rthexplorer.sh status
```

## Compatibility

RTHexplorer works with Huawei devices that use the **HiLink web API** — the local web interface found on Huawei 4G/LTE and 5G routers, mobile Wi-Fi hotspots and HiLink USB modems. To send SMS, the device must of course have a SIM card with an SMS-capable plan.

### Supported login methods

The script asks the device which login it expects (`/api/user/state-login`) and picks the right one automatically:

| Login method | Typically found on | Supported |
|---|---|---|
| No password (`State 0`) | HiLink USB modems, devices without login | ✅ |
| Base64 password (`password_type 0` or `3`) | Older firmwares | ✅ |
| SHA-256 password (`password_type 4`) | Most 4G/LTE routers and hotspots | ✅ |
| SCRAM challenge (`challenge_login` / `authentication_login`) | Recent web interfaces, 5G CPE | ✅ (`rthexplorer_bash.sh` needs OpenSSL 3.0+) |
| RSA-encrypted login | A few recent firmwares | ❌ |

The anti-CSRF token is read from the home page (`<meta name="csrf_token">`) or, when a firmware doesn't publish it there, from `/api/webserver/SesTokInfo`.

### Devices

**✅ Tested with RTHexplorer**

| Model | Type | Login method | Result |
|---|---|---|---|
| **B525s-23a** | 4G/LTE router | SHA-256 (`password_type 4`) | `send` and `status` working (author's device) |

**Expected to work**

The models below are known to expose this same HiLink API (device list from the [huawei-lte-api](https://github.com/Salamek/huawei-lte-api) project). They have **not** been individually tested with this script yet — **reports are welcome**.

**4G/LTE routers**

| Series | Models |
|---|---|
| B31x | B310s-22, B311-221, B315s-22 |
| B5xx | B525s-23a ✅, B525s-65a, B528s, B535-232, SoyeaLink B535-333 |
| B6xx | B612-233, B628-265 |
| B7xx / B8xx | B715s-23c, B818-263 |
| E51xx (home routers) | E5180s-22, E5186s-22a |

**Mobile Wi-Fi hotspots (MiFi) and Wingles**

| Models |
|---|
| E5573s-320, E5576-320, E5577Cs-321, E8231 |

**USB modems** — only in **HiLink** (network) mode, not in serial "stick" mode

| Models |
|---|
| E3131, E3372, E3531, E5530As-2, E8372h-608 |

**5G routers** (SCRAM login)

| Models |
|---|
| 5G CPE Pro (H112-372), 5G CPE Pro 2 (H122-373), 5G CPE 6 (H165-383) |

Other Huawei devices with the same web interface will probably work too.

### Not compatible

- **B2368-22** and **B593s-22**: different firmware/API
- USB modems running the **serial ("stick") firmware** instead of HiLink
- Firmwares that only accept the **RSA-encrypted** login

### Report your device

Please [open an issue](https://github.com/StraySnake/RTHexplorer/issues) with your **model**, **firmware version**, the script you used and the result of `./rthexplorer.sh status` (it never shows your password). Confirmed models will be added to this list.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `router unreachable` | Router powered on? Correct `HUAWEI_ROUTER_URL`? Try `http://` instead of `https://`. Can you open the router web page from this machine? |
| `login refused: wrong username or password` | Same credentials as the router web page? Special characters are fine inside quotes in the config file. |
| `login refused: too many attempts` | The router locks logins after several failures. Wait a few minutes. |
| `login refused: another session is already open` | Log out from the router web page in your browser. |
| `login refused: the router asks to change the default password first` | Log in once in the router web page and set a new password. |
| `login aborted: the router's identity could not be verified` | SCRAM signature mismatch: make sure you are really talking to your router (check `HUAWEI_ROUTER_URL`). |
| `anti-CSRF token not found` | Your firmware may use a different API. Please [open an issue](https://github.com/StraySnake/RTHexplorer/issues) with your model. |
| `could not compute the SCRAM login` | `rthexplorer_bash.sh` on a SCRAM device needs OpenSSL 3.0 or newer — or use `rthexplorer.sh`. |
| `SIM card missing, locked or waiting for PIN` | Insert the SIM, or enter/disable the PIN in the router web page. |
| `no mobile network` | Antenna, coverage, data/SMS plan, operator outage. |
| `SMS refused by the router` | SMS allowed by your plan? Valid international number? SMS storage full (delete old messages in the router web page)? |

## Security notes

- Store the password in `rthexplorer.conf` with `chmod 600`, or provide it through an environment variable. **Never commit `rthexplorer.conf`** (it is listed in `.gitignore`).
- The router uses a self-signed HTTPS certificate, so certificate verification is disabled (`curl --insecure`). Only use the script on a trusted local network.
- The script logs out from the router at the end of every run, even after an error, so it never leaves a session open.
- Messages and numbers are XML-escaped before being sent; the config file is parsed, not executed.

## How it works

1. Open a session: `GET /html/home.html` (session cookie + anti-CSRF token)
2. Detect the login method: `GET /api/user/state-login`
3. Log in, depending on the device:
   - SCRAM: `POST /api/user/challenge_login` then `POST /api/user/authentication_login` (the router's signature is checked)
   - SHA-256: `POST /api/user/login` with `base64(sha256hex(username + base64(sha256hex(password)) + token))`
   - Base64: `POST /api/user/login` with `base64(password)`
   - No password: nothing to do
4. Get a fresh token: `GET /api/webserver/token`
5. `send` → `POST /api/sms/send-sms` · `status` → `GET /api/monitoring/status` and `GET /api/net/current-plmn`
6. Log out: `POST /api/user/logout`

## License

Copyright (C) 2026 StraySnake

RTHexplorer is free software, released under the **GNU General Public License v3.0 or later** — see [LICENSE](LICENSE).

You may use, study, modify and share it. If you distribute a modified version, it must stay under the GPL and its source code must be made available.
