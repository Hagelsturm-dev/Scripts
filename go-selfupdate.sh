#!/bin/bash

set -e

INSTALL_DIR="/hdd/"
GO_DIR="$INSTALL_DIR/go"

if ! command -v go &> /dev/null; then
    CURRENT_VER="none"
else
    CURRENT_VER=$(go version | awk '{print $3}')
fi

LATEST_VER=$(curl -s https://go.dev/VERSION?m=text | head -n 1)

if [ "$CURRENT_VER" == "$LATEST_VER" ]; then
    echo "✅ Go ist bereits aktuell: $CURRENT_VER"
    exit 0
fi

echo "⬆️  Update verfuegbar: $CURRENT_VER ➜ $LATEST_VER"

ARCH=$(uname -m)
OS=$(uname | tr '[:upper:]' '[:lower:]')

# Architektur zu Go-kompatiblem Wert übersetzen
case "$ARCH" in
    x86_64)
        GOARCH="amd64"
        ;;
    aarch64 | arm64)
        GOARCH="arm64"
        ;;
    armv7l)
        GOARCH="armv6l"  # Go bietet ARMv6-Build, kompatibel mit v7
        ;;
    *)
        echo "❌ Nicht unterstützte Architektur: $ARCH"
        exit 1
        ;;
esac


if [ "$GOARCH" = "armv6l" ]; then
    FILENAME="$LATEST_VER.linux-armv6l.tar.gz"
else
    FILENAME="$LATEST_VER.$OS-$GOARCH.tar.gz"
fi

DOWNLOAD_URL="https://go.dev/dl/$FILENAME"

echo "⬇️  Lade herunter: $FILENAME"
curl -LO "$DOWNLOAD_URL"

echo "🧹 Entferne alte Go-Version (falls vorhanden)..."
rm -rf "$GO_DIR"

echo "📦 Entpacke neue Version nach $INSTALL_DIR"
tar -C "$INSTALL_DIR" -xzf "$FILENAME"

echo "🧽 Clean..."
rm "$FILENAME"

echo "✅ Go $LATEST_VER erfolgreich installiert!"
echo "🔁 Starte Terminal neu oder füge folgendes in ~/.bashrc oder ~/.profile ein:"
echo '   export PATH=$PATH:/hdd/go/bin'

