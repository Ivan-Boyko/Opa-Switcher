#!/bin/bash
# Сборка Опа.app.
#   ./build.sh           — собрать build.noindex/Опа.app
#   ./build.sh run       — собрать и запустить
#   ./build.sh install   — собрать, положить в /Applications и запустить
#   ./build.sh release   — собрать для Apple Silicon и Intel и упаковать в dist/Opa-<версия>.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Опа"  # имя в Finder, Spotlight и настройках
NAME=Opa        # цель SwiftPM, исполняемый файл и процесс
# .noindex — чтобы Spotlight не показывал сборку рядом с установленной копией.
APP="build.noindex/$APP_NAME.app"
# Релиз — для обоих процессоров; для себя — быстрее, только под этот Mac.
ARCH_FLAGS=""
[ "${1:-}" = release ] && ARCH_FLAGS="--arch arm64 --arch x86_64"

swift build -c release $ARCH_FLAGS --product "$NAME"
BIN="$(swift build -c release $ARCH_FLAGS --show-bin-path)/$NAME"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/en.txt Resources/ru.txt Resources/AppIcon.icns "$APP/Contents/Resources/"

# Подпись одним и тем же сертификатом — чтобы доступ «Универсальный доступ» переживал пересборку и обновления.
# Какой — из SIGN_IDENTITY или файла .sign-identity (имя или хэш), для релиза — из .release-identity.
# Ищем по имени, чтобы перевыпущенный сертификат с тем же именем подхватился сам.
# Не задан — первый «Apple Development»; нет и его — ad-hoc (доступ слетает после каждой сборки).
if [ "${1:-}" = release ]; then
  # В релиз — отдельный сертификат (tools/make-release-cert.sh): в «Apple Development» вшит email автора.
  WANTED="${SIGN_IDENTITY:-$(cat .release-identity 2>/dev/null || echo "Opa Release")}"
else
  WANTED="${SIGN_IDENTITY:-$(cat .sign-identity 2>/dev/null || true)}"
fi
VALID="$(security find-identity -v -p codesigning | grep -v CSSMERR || true)"
if [ -n "$WANTED" ]; then
  IDENTITY="$(echo "$VALID" | grep -F "$WANTED" | head -1 | awk '{print $2}' || true)"
  [ -n "$IDENTITY" ] || { echo "Сертификат не найден: $WANTED"; exit 1; }
else
  IDENTITY="$(echo "$VALID" | grep "Apple Development" | head -1 | awk '{print $2}' || true)"
fi
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Собрано: $APP (подпись: ${IDENTITY:-ad-hoc}, процессоры: $(lipo -archs "$APP/Contents/MacOS/$NAME"))"

case "${1:-}" in
  run)
    pkill -x "$NAME" || true
    open "$APP"
    ;;
  install)
    pkill -x "$NAME" || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    open "/Applications/$APP_NAME.app"
    echo "Установлено: /Applications/$APP_NAME.app"
    ;;
  release)
    VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)"
    DMG="dist/Opa-$VERSION.dmg"
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    mkdir -p dist
    rm -f "$DMG"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGING"
    echo "Релиз: $DMG"
    shasum -a 256 "$DMG"
    ;;
esac
