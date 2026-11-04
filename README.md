RTHexplorer

Send SMS and check the status of a Huawei 4G/LTE router from the command line — using only the router's local web API.

    No cloud, no app, no extra software on the router: it talks to the same local API as the router's web page.
    Two commands: send an SMS, or check the router status (login, SIM card, mobile network, signal) without sending anything.
    Script-friendly: one machine-readable result line on stdout, progress on stderr, meaningful exit codes.
    Lightweight: a single Bash script. Works on Raspberry Pi, NAS, Docker/Alpine containers, any Linux or macOS machine on the router's network.

Typical uses: alerts from security cameras or home automation, server monitoring, backup reports, door sensors, cron jobs… anything that can run a shell command.
Contents

    Requirements
    Installation
    Configuration
    Usage
    Output and exit codes
    Examples
    Compatibility
    Troubleshooting
    Security notes
    How it works
    License

Requirements

    A Huawei 4G/LTE router with a SIM card that can send SMS
    A machine on the same network as the router, with:
        bash
        curl
        python3 (standard library only)
        awk, mktemp (present on virtually every system)

No openssl, no GNU-only grep -P: the script also runs on minimal images (Alpine, BusyBox).
Installation

git clone https://github.com/StraySnake/RTHexplorer.git
cd RTHexplorer
chmod +x rthexplorer.sh
cp rthexplorer.conf.example rthexplorer.conf
chmod 600 rthexplorer.conf

Then edit rthexplorer.conf (see below) and check that everything works:

./rthexplorer.sh status

Configuration

Settings are read from a config file and/or environment variables. Environment variables take precedence.
Setting	Default	Description
HUAWEI_ROUTER_URL	https://192.168.8.1	Router web address. Use http://… if your router has no HTTPS.
HUAWEI_USERNAME	admin	Router administrator account
HUAWEI_PASSWORD	(required)	Router administrator password
HUAWEI_CONFIG	rthexplorer.conf next to the script	Path of the config file
Config file

rthexplorer.conf contains plain KEY=VALUE lines (quotes optional, # for comments). It is read, never executed.

HUAWEI_ROUTER_URL=https://192.168.8.1
HUAWEI_USERNAME=admin
HUAWEI_PASSWORD="my router password"

Environment variables

HUAWEI_PASSWORD='my router password' ./rthexplorer.sh status

Usage

rthexplorer.sh send <phone_number> <message>   Send an SMS
rthexplorer.sh status                          Check the router (no SMS sent)
rthexplorer.sh help                            Show help

A short form is also accepted for compatibility: rthexplorer.sh <phone_number> <message>.

Use international phone numbers, e.g. +33612345678.
Send an SMS

./rthexplorer.sh send +33612345678 "Front door opened at $(date +%H:%M)"

Check the router without sending anything

./rthexplorer.sh status

It logs in, reads the SIM card state, the mobile network and the signal strength, then logs out. Ideal for a daily health check: you learn that SMS alerts are broken before you need them.
Output and exit codes

Progress messages are written to stderr:

[INFO] Connecting to https://192.168.8.1...
[OK] Session opened
[OK] Logged in as admin
[INFO] Sending SMS to +33612345678...
[OK] SMS accepted by the router

Exactly one result line is written to stdout, easy to parse:
Situation	stdout
SMS sent	STATUS=OK;SMS=sent
Router healthy	STATUS=OK;SIGNAL=4/5;OPERATOR=Orange F
Any problem	STATUS=ERROR;DETAIL=<reason>

Examples of DETAIL:

    router unreachable at https://192.168.8.1 (powered off, cable, network?)
    login refused: wrong username or password (code 108006)
    login refused: too many attempts, try again later (code 108007)
    SIM card missing, locked or waiting for PIN (SimStatus=0)
    no mobile network (signal 0/5)
    SMS refused by the router (code …)

Exit code	Meaning
0	Success
1	Failure (see DETAIL)
2	Wrong usage (missing arguments)

    "SMS accepted by the router" means the router queued the message. As with any SMS, delivery to the phone depends on the mobile network.

Examples

Daily health check with cron (alert by e-mail if the router is not ready):

0 9 * * * /opt/RTHexplorer/rthexplorer.sh status >/dev/null 2>&1 || echo "SMS router not ready" | mail -s "SMS alert" you@example.com

Use the result in a script:

result="$(./rthexplorer.sh status 2>/dev/null)"
if [[ "$result" == STATUS=OK* ]]; then
    echo "Router ready: ${result#STATUS=OK;}"
else
    echo "Problem: ${result#*DETAIL=}"
fi

Notify several people:

for number in +33611111111 +33622222222; do
    ./rthexplorer.sh send "$number" "Backup finished"
done

Home automation (example: a Home Assistant shell_command):

shell_command:
  send_sms: >-
    bash /config/scripts/rthexplorer.sh send {{ number | to_json }} {{ message | to_json }}
  sms_router_status: bash /config/scripts/rthexplorer.sh status

Compatibility

The script uses the Huawei "HiLink" web API with the SHA-256 login scheme (password_type 4) found on many Huawei 4G/LTE routers and mobile Wi-Fi devices.

It reads the anti-CSRF token either from the home page (<meta name="csrf_token">) or, on firmwares that don't publish it there, from /api/webserver/SesTokInfo.

It has been used on the author's Huawei 4G router. Other models using the same web API should work; firmwares with a different login scheme (older password_type 3, or newer encrypted logins) are not supported. Reports of tested models are welcome — please open an issue or a pull request with your model and firmware version.
Troubleshooting
Symptom	What to check
router unreachable	Router powered on? Correct HUAWEI_ROUTER_URL? Try http:// instead of https://. Can you open the router web page from this machine?
login refused: wrong username or password	Same credentials as the router web page? Special characters are fine inside quotes in the config file.
login refused: too many attempts	The router locks logins after several failures. Wait a few minutes.
login refused: another session is already open	Log out from the router web page in your browser.
anti-CSRF token not found	Your firmware may use a different API. Please open an issue with your model.
SIM card missing, locked or waiting for PIN	Insert the SIM, or enter/disable the PIN in the router web page.
no mobile network	Antenna, coverage, data/SMS plan, operator outage.
SMS refused by the router	SMS allowed by your plan? Valid international number? SMS storage full (delete old messages in the router web page)?
Security notes

    Store the password in rthexplorer.conf with chmod 600, or provide it through an environment variable. Never commit rthexplorer.conf (it is listed in .gitignore).
    The router uses a self-signed HTTPS certificate, so certificate verification is disabled (curl --insecure). Only use the script on a trusted local network.
    The script logs out from the router at the end of every run, even after an error, so it never leaves a session open.
    Messages and numbers are XML-escaped before being sent; the config file is parsed, not executed.

How it works

    Open a session: GET /html/home.html (session cookie + anti-CSRF token)
    Log in: POST /api/user/login with base64(sha256hex(username + base64(sha256hex(password)) + token))
    Get a fresh token: GET /api/webserver/token
    send → POST /api/sms/send-sms · status → GET /api/monitoring/status and GET /api/net/current-plmn
    Log out: POST /api/user/logout

License

MIT — see LICENSE.

