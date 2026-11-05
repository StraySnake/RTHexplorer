#!/usr/bin/env python3
"""Simulated Huawei HiLink router used by the automated tests.

Usage: mock_router.py <mode> <port> <certfile> <keyfile> <logdir>

Modes (login behaviour of the simulated firmware):
  sha256   password_type 4, classic SHA-256 login (most 4G routers)
  scram    password_type 4, SCRAM login only (recent web UIs, 5G CPE)
  b64      password_type 0, base64 login (older firmwares)
  type3    password_type 3, base64 login
  nologin  no login needed (HiLink USB modems)
  nostate  /api/user/state-login not supported
  sestok   token only published by /api/webserver/SesTokInfo
  nosim    SIM card missing
  badpw    every login is refused
  single   one session at a time, like real routers: a new login invalidates
           the previous session (error 125003) — tests the lock between runs
  flaky    the first login is rejected with 125003 (session error), then OK

Expected credentials: admin / p@ss w0rd"x (a space and a quote, to test escaping).
Sent SMS are appended to <logdir>/sent.log as "<phone>|<content>|<length>",
every POST path to <logdir>/calls.log, reboot requests to <logdir>/control.log.
"""

import base64
import hashlib
import hmac
import http.server
import re
import ssl
import sys

MODE, PORT, CERT, KEY, LOGDIR = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
USERNAME = "admin"
PASSWORD = 'p@ss w0rd"x'
TOKEN = "TOK123"
SALT, ITERATIONS = "a1b2c3d4e5f60718", 100
REFUSED_PHONE = "+33699999999"

import time

state = {
    "logged": False,
    "session": "",
    "sessions": 0,
    "flaky_done": False,
    "first_nonce": "",
    # box 1 = received (index: read flag), box 2 = sent
    "boxes": {
        1: {"40001": 0, "40002": 0, "40003": 1},
        2: {str(20000 + i): 1 for i in range(60)},
    },
}
INBOX_CONTENT = {
    "40001": ("+33611111111", "STATUS", "2026-11-04 21:00:00"),
    "40002": ("+33622222222", "Lights off &amp; thanks été \"ok\"", "2026-11-04 21:01:00"),
    "40003": ("+33633333333", "old", "2026-11-03 10:00:00"),
}


def sha_b64(text):
    return base64.b64encode(hashlib.sha256(text.encode()).hexdigest().encode()).decode()


def scram(first, server):
    auth = f"{first},{server},{server}".encode()
    salted = hashlib.pbkdf2_hmac("sha256", PASSWORD.encode(), bytes.fromhex(SALT), ITERATIONS, 32)
    client_key = hmac.new(b"Client Key", salted, hashlib.sha256).digest()
    signature = hmac.new(auth, hashlib.sha256(client_key).digest(), hashlib.sha256).digest()
    proof = bytes(a ^ b for a, b in zip(client_key, signature)).hex()
    server_sig = hmac.new(auth, hmac.new(b"Server Key", salted, hashlib.sha256).digest(), hashlib.sha256).hexdigest()
    return proof, server_sig


def tag(body, name):
    match = re.search(r"<%s>([^<]*)</%s>" % (name, name), body)
    return match.group(1) if match else ""


def log(name, line):
    with open(f"{LOGDIR}/{name}", "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


class Router(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, body, cookie=False, token=None, session=None):
        self.send_response(200)
        if cookie:
            self.send_header("Set-Cookie", "SessionID=abc123; path=/")
        if session:
            self.send_header("Set-Cookie", f"SessionID={session}; path=/")
        if token:
            self.send_header("__RequestVerificationToken", token)
        self.end_headers()
        self.wfile.write(body.encode())

    def stolen(self):
        """single mode: is this request using a session replaced by a newer login?"""
        if MODE != "single" or not state["session"]:
            return False
        return f"SessionID={state['session']}" not in (self.headers.get("Cookie") or "")

    def error(self, code):
        self.reply(f"<error><code>{code}</code><message></message></error>")

    def do_GET(self):
        path = self.path
        if path == "/html/home.html":
            meta = "" if MODE == "sestok" else f'<meta name="csrf_token" content="{TOKEN}"/>'
            return self.reply(f"<html><head>{meta}</head></html>", cookie=True)
        if path == "/api/webserver/SesTokInfo":
            return self.reply(f"<response><SesInfo>SessionID=abc123</SesInfo><TokInfo>{TOKEN}</TokInfo></response>")
        if path == "/api/webserver/token":
            return self.reply("<response><token>NEWTOKEN</token></response>")
        if path == "/api/user/state-login":
            if MODE == "nostate":
                return self.error(100002)
            logged = "0" if MODE == "nologin" else "-1"
            ptype = {"b64": "0", "type3": "3"}.get(MODE, "4")
            return self.reply(f"<response><State>{logged}</State><password_type>{ptype}</password_type></response>")
        if not state["logged"] and MODE != "nologin":
            return self.error(100003)
        if self.stolen():
            return self.error(125003)
        if path == "/api/monitoring/status":
            sim = "0" if MODE == "nosim" else "1"
            return self.reply("<response><ConnectionStatus>901</ConnectionStatus>"
                              f"<SimStatus>{sim}</SimStatus><SignalIcon>4</SignalIcon>"
                              "<CurrentNetworkType>19</CurrentNetworkType>"
                              "<CurrentNetworkTypeEx>1011</CurrentNetworkTypeEx></response>")
        if path == "/api/net/current-plmn":
            return self.reply("<response><ShortName>Test Mobile</ShortName></response>")
        if path == "/api/device/signal":
            return self.reply("<response><rsrp>-97dBm</rsrp><rsrq>-11dB</rsrq>"
                              "<rssi>&gt;=-51dBm</rssi><sinr>9dB</sinr></response>")
        if path == "/api/sms/sms-count":
            boxes = state["boxes"]
            return self.reply(f"<response><LocalInbox>{len(boxes[1])}</LocalInbox>"
                              f"<LocalOutbox>{len(boxes[2])}</LocalOutbox><LocalMax>500</LocalMax></response>")
        return self.error(100002)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        path = self.path
        log("calls.log", path)

        if path == "/api/user/challenge_login":
            if MODE != "scram":
                return self.error(100002)
            state["first_nonce"] = tag(body, "firstnonce")
            server = state["first_nonce"] + "SRV"
            return self.reply(f"<response><salt>{SALT}</salt><iterations>{ITERATIONS}</iterations>"
                              f"<servernonce>{server}</servernonce></response>", token="SCRAMTOKEN#X")
        if path == "/api/user/authentication_login":
            if self.headers.get("__RequestVerificationToken") != "SCRAMTOKEN":
                return self.error(125002)
            server = state["first_nonce"] + "SRV"
            proof, server_sig = scram(state["first_nonce"], server)
            if tag(body, "clientproof") != proof:
                return self.error(108006)
            state["logged"] = True
            return self.reply(f"<response><serversignature>{server_sig}</serversignature></response>")
        if path == "/api/user/login":
            if MODE in ("scram", "badpw"):
                return self.error(108006)
            if MODE == "flaky" and not state["flaky_done"]:
                state["flaky_done"] = True
                return self.error(125003)
            ptype, password = tag(body, "password_type"), tag(body, "Password")
            if ptype == "4":
                good = password == sha_b64(USERNAME + sha_b64(PASSWORD) + TOKEN)
            else:
                good = (password == base64.b64encode(PASSWORD.encode()).decode()
                        and ptype == {"b64": "0", "type3": "3"}.get(MODE))
            if not good:
                return self.error(108006)
            state["logged"] = True
            if MODE == "single":
                state["sessions"] += 1
                state["session"] = f"s{state['sessions']}"
                return self.reply("<response>OK</response>", session=state["session"])
            return self.reply("<response>OK</response>")
        if path == "/api/user/logout":
            if self.stolen():
                return self.error(125003)
            state["logged"] = False
            return self.reply("<response>OK</response>")

        if not state["logged"] and MODE != "nologin":
            return self.error(100003)
        if self.stolen():
            return self.error(125003)

        if path == "/api/sms/send-sms":
            if MODE == "single":
                time.sleep(0.4)   # long enough for another run to try to log in meanwhile
                if self.stolen():
                    return self.error(125003)
            phone = tag(body, "Phone")
            log("sent.log", f"{phone}|{tag(body, 'Content')}|{tag(body, 'Length')}")
            if phone == REFUSED_PHONE:
                return self.error(113004)
            return self.reply("<response>OK</response>")
        if path == "/api/sms/sms-list":
            box, page = int(tag(body, "BoxType")), int(tag(body, "PageIndex"))
            indexes = sorted(state["boxes"][box])[(page - 1) * 50:page * 50]
            messages = ""
            for index in indexes:
                phone, content, date = INBOX_CONTENT.get(index, ("+33600000000", "x", "2026-11-01 00:00:00"))
                messages += (f"<Message>\n<Smstat>{state['boxes'][box][index]}</Smstat>\n<Index>{index}</Index>\n"
                             f"<Phone>{phone}</Phone>\n<Content>{content}</Content>\n<Date>{date}</Date>\n</Message>")
            return self.reply(f"<response><Count>{len(state['boxes'][box])}</Count><Messages>{messages}</Messages></response>")
        if path == "/api/sms/set-read":
            index = tag(body, "Index")
            if index in state["boxes"][1]:
                state["boxes"][1][index] = 1
            return self.reply("<response>OK</response>")
        if path == "/api/sms/delete-sms":
            index = tag(body, "Index")
            for box in state["boxes"].values():
                box.pop(index, None)
            return self.reply("<response>OK</response>")
        if path == "/api/device/control":
            log("control.log", tag(body, "Control"))
            return self.reply("<response>OK</response>")
        return self.error(100002)


context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(CERT, KEY)
server = http.server.HTTPServer(("127.0.0.1", PORT), Router)
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
