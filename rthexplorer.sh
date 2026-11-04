#!/bin/bash

set -euo pipefail

# ============================================================
# CONFIGURATION ROUTEUR HUAWEI 4G
# ============================================================

ROUTER_IP="192.168.8.1"
USERNAME="admin"
PASSWORD="TON_MOT_DE_PASSE"

# ============================================================
# ARGUMENTS
# ============================================================

PHONE_NUMBER="${1:-}"
MESSAGE="${2:-}"

if [[ -z "$PHONE_NUMBER" || -z "$MESSAGE" ]]; then
    echo "Usage: $0 <phone_number> <message>"
    exit 1
fi

# ============================================================
# VERIFICATION DES DEPENDANCES
# ============================================================

for cmd in curl python3 grep awk mktemp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERREUR : commande manquante : $cmd"
        exit 1
    fi
done

# ============================================================
# FONCTION SHA256 HEX -> BASE64
# Remplace OpenSSL par Python 3
# ============================================================

sha256_hexstring_to_base64() {

    printf '%s' "$1" | python3 -c '
import sys
import hashlib
import base64

data = sys.stdin.buffer.read()

sha256_hex = hashlib.sha256(data).hexdigest()

result = base64.b64encode(
    sha256_hex.encode("ascii")
)

sys.stdout.write(result.decode("ascii"))
'
}

# ============================================================
# PROTECTION XML
# ============================================================

xml_escape() {

    printf '%s' "$1" | python3 -c '
import sys
from xml.sax.saxutils import escape

data = sys.stdin.read()
sys.stdout.write(escape(data))
'
}

# ============================================================
# INITIALISATION
# ============================================================

echo "[INFO] Initialisation du modem Huawei..."
echo "[INFO] Routeur : $ROUTER_IP"

COOKIE_JAR=$(mktemp)

# Supprimer automatiquement les cookies en fin de script
trap 'rm -f -- "$COOKIE_JAR"' EXIT

# Options CURL
# -k : certificat HTTPS du routeur non vérifié
# -s : mode silencieux
# -S : afficher les erreurs
# -Connect timeout : 5 secondes
# -Max time : 10 secondes

CURL_OPTIONS=(
    -k
    -s
    -S
    --connect-timeout 5
    --max-time 10
)

# ============================================================
# ETAPE 1 : CONNEXION AU ROUTEUR
# ============================================================

echo "[INFO] Connexion au routeur..."

RESPONSE=$(curl "${CURL_OPTIONS[@]}" \
    -D - \
    --cookie-jar "$COOKIE_JAR" \
    "https://$ROUTER_IP/html/home.html")

# ============================================================
# ETAPE 2 : RECUPERATION SESSION ID
# ============================================================

SESSIONID=$(awk '$6 == "SessionID" {print $7}' "$COOKIE_JAR" | tail -n 1)

if [[ -z "$SESSIONID" ]]; then
    echo "[ERREUR] SessionID introuvable"
    exit 1
fi

echo "[OK] Session initialisée"

# ============================================================
# ETAPE 3 : RECUPERATION TOKEN CSRF
# ============================================================

CSRF_TOKEN=$(
    printf '%s' "$RESPONSE" |
    grep -oP '<meta name="csrf_token" content="\K[^"]+' |
    tail -n 1
) || true

CSRF_TOKEN=$(printf '%s' "$CSRF_TOKEN" | tr -cd '[:alnum:]')

if [[ -z "$CSRF_TOKEN" ]]; then
    echo "[ERREUR] Token CSRF introuvable"
    exit 1
fi

echo "[OK] Token CSRF récupéré"

# ============================================================
# ETAPE 4 : CALCUL DU MOT DE PASSE HUAWEI
# ============================================================

echo "[INFO] Calcul du hash du mot de passe..."

PASSWORD_HASHED=$(sha256_hexstring_to_base64 "$PASSWORD")

CONCAT="${USERNAME}${PASSWORD_HASHED}${CSRF_TOKEN}"

FINAL_PASSWORD=$(sha256_hexstring_to_base64 "$CONCAT")

echo "[OK] Hash calculé"

# ============================================================
# ETAPE 5 : AUTHENTIFICATION
# ============================================================

echo "[INFO] Authentification au routeur..."

LOGIN_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<request>
    <Username>$USERNAME</Username>
    <Password>$FINAL_PASSWORD</Password>
    <password_type>4</password_type>
</request>"

LOGIN_RESPONSE=$(curl "${CURL_OPTIONS[@]}" \
    -b "$COOKIE_JAR" \
    --cookie-jar "$COOKIE_JAR" \
    -H "__RequestVerificationToken: $CSRF_TOKEN" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -X POST \
    "https://$ROUTER_IP/api/user/login" \
    --data "$LOGIN_XML")

if echo "$LOGIN_RESPONSE" | grep -q "<response>OK</response>"; then

    echo "[OK] Authentification réussie"

else

    echo "[ERREUR] Authentification refusée"
    echo "$LOGIN_RESPONSE"

    exit 1

fi

# ============================================================
# ETAPE 6 : NOUVEAU TOKEN CSRF
# ============================================================

echo "[INFO] Récupération du token SMS..."

TOKEN_RESPONSE=$(curl "${CURL_OPTIONS[@]}" \
    -b "$COOKIE_JAR" \
    "https://$ROUTER_IP/api/webserver/token")

NEW_CSRF_TOKEN=$(
    printf '%s' "$TOKEN_RESPONSE" |
    grep -oP '<token>\K[^<]+' |
    head -n 1
) || true

if [[ -z "$NEW_CSRF_TOKEN" ]]; then

    echo "[ERREUR] Impossible de récupérer le token SMS"

    exit 1

fi

echo "[OK] Token SMS récupéré"

# ============================================================
# ETAPE 7 : PREPARATION DU SMS
# ============================================================

echo "[INFO] Préparation du SMS..."

PHONE_XML=$(xml_escape "$PHONE_NUMBER")
MESSAGE_XML=$(xml_escape "$MESSAGE")

MESSAGE_LENGTH=$(
    python3 -c 'import sys; print(len(sys.argv[1]))' "$MESSAGE"
)

SMS_DATE=$(date "+%Y-%m-%d %H:%M:%S")

SMS_XML="<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<request>
    <Index>-1</Index>
    <Phones>
        <Phone>$PHONE_XML</Phone>
    </Phones>
    <Sca></Sca>
    <Content>$MESSAGE_XML</Content>
    <Length>$MESSAGE_LENGTH</Length>
    <Reserved>1</Reserved>
    <Date>$SMS_DATE</Date>
</request>"

# ============================================================
# ETAPE 8 : ENVOI DU SMS
# ============================================================

echo "[INFO] Envoi du SMS..."

SMS_RESPONSE=$(curl "${CURL_OPTIONS[@]}" \
    -b "$COOKIE_JAR" \
    -H "__RequestVerificationToken: $NEW_CSRF_TOKEN" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -X POST \
    "https://$ROUTER_IP/api/sms/send-sms" \
    --data "$SMS_XML")

# ============================================================
# ETAPE 9 : VERIFICATION
# ============================================================

if echo "$SMS_RESPONSE" | grep -q "<response>OK</response>"; then

    echo "============================================"
    echo "[OK] SMS accepté par le modem"
    echo "============================================"

    exit 0

else

    echo "============================================"
    echo "[ERREUR] Envoi du SMS refusé"
    echo "============================================"

    echo "$SMS_RESPONSE"

    exit 1

fi
