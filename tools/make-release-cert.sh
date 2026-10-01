#!/bin/bash
# Один раз на машине, где собираются релизы: создаёт самоподписанный сертификат «Opa Release».
# Все релизы подписываются им, поэтому у пользователей доступ «Универсальный доступ» переживает обновления.
# Закрытый ключ остаётся в связке ключей «Вход» и в репозиторий не попадает. macOS спросит пароль,
# чтобы доверить сертификату подпись кода.
set -euo pipefail
NAME="Opa Release"
if security find-identity -v -p codesigning | grep -qF "\"$NAME\""; then
  echo "Сертификат «$NAME» уже есть."
  exit 0
fi
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
# Системный openssl (LibreSSL): его .p12 понимает `security import`.
/usr/bin/openssl req -new -newkey rsa:2048 -nodes -x509 -days 3650 -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -out "$DIR/cert.p12" \
  -name "$NAME" -passout pass:opa
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$DIR/cert.p12" -k "$KEYCHAIN" -P opa -T /usr/bin/codesign >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$DIR/cert.pem"
security find-identity -v -p codesigning | grep -F "$NAME"
