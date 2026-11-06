#!/bin/bash
# Збирає програму «Станція» (патужно) для macOS і встановлює її в /Applications.
# Потрібні Xcode Command Line Tools: xcode-select --install
# Адреса вашого сервера (необов'язково) — у файлі server.url поруч із цим скриптом (див. server.url.example).
set -u
cd "$(dirname "$0")"
LOG="$PWD/build.log"; : > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
say "== Збірка «Станції» $(date)"

if ! xcode-select -p >/dev/null 2>&1; then
  say "Потрібні Xcode Command Line Tools. Запускаю встановлення — після нього запустіть цей файл ще раз."
  xcode-select --install; exit 1
fi

SERVER=""; [ -f server.url ] && SERVER="$(head -1 server.url | tr -d '[:space:]')"
[ -n "$SERVER" ] && say "сервер: $SERVER" || say "сервер не вказано (server.url) — хмара, Telegram і панель на телефоні будуть вимкнені"

APP="Станція"; ID="ua.oukitel.stantsiya"
TMP="$(mktemp -d)"; B="$TMP/$APP.app/Contents"
mkdir -p "$B/MacOS" "$B/Resources"

say "компілюю…"
if ! xcrun swiftc -O -o "$B/MacOS/$APP" app/Core.swift app/Engine.swift app/Setup.swift app/Health.swift app/Cloud.swift app/main.swift >>"$LOG" 2>&1; then
  say "ПОМИЛКА компіляції — подробиці в build.log"; tail -30 "$LOG"; exit 1
fi

cp app/dashboard.html app/panel.html app/logo.png "$B/Resources/"
# іконка: з app/AppIcon.icns; якщо її немає — з уже встановленої програми; інакше без іконки
if [ -f app/AppIcon.icns ]; then cp app/AppIcon.icns "$B/Resources/"
elif [ -f "/Applications/$APP.app/Contents/Resources/AppIcon.icns" ]; then cp "/Applications/$APP.app/Contents/Resources/AppIcon.icns" "$B/Resources/"; cp "$B/Resources/AppIcon.icns" app/ 2>/dev/null
fi

cat > "$B/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>$APP</string>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSLocalNetworkUsageDescription</key><string>Станція читає дані зарядної станції Oukitel у домашній мережі.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>PatuzhnoServer</key><string>$SERVER</string>
</dict></plist>
EOF

codesign --force --deep --sign - "$TMP/$APP.app" >>"$LOG" 2>&1 && say "підписано (локально)"

say "== Зупиняю попередню версію"
pkill -x "$APP" 2>/dev/null; sleep 1
rm -rf "/Applications/$APP.app"
if ! cp -R "$TMP/$APP.app" /Applications/; then say "ПОМИЛКА: не вдалося скопіювати в /Applications"; exit 1; fi
rm -rf "$TMP"
open "/Applications/$APP.app"
say "BUILD_OK: /Applications/$APP.app"
