#!/bin/bash
set -e

echo "=== Installing AWS Session Manager Plugin ==="
echo ""

# Detect architecture
ARCH=$(uname -m)
OS=$(uname -s)

echo "Detected OS: $OS"
echo "Detected Architecture: $ARCH"
echo ""

if [ "$OS" = "Linux" ]; then
  if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    # Linux ARM64
    echo "Installing Session Manager Plugin for Linux ARM64..."
    PACKAGE="ubuntu_arm64/session-manager-plugin.deb"
  elif [ "$ARCH" = "x86_64" ]; then
    # Linux x86_64
    echo "Installing Session Manager Plugin for Linux x86_64..."
    PACKAGE="ubuntu_64bit/session-manager-plugin.deb"
  else
    echo "ERROR: Unsupported Linux architecture: $ARCH"
    exit 1
  fi

  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/$PACKAGE" -o "/tmp/session-manager-plugin.deb"

  echo ""
  echo "Installing package (requires sudo)..."
  sudo dpkg -i /tmp/session-manager-plugin.deb
  rm /tmp/session-manager-plugin.deb

elif [ "$OS" = "Darwin" ]; then
  if [ "$ARCH" = "arm64" ]; then
    # macOS Apple Silicon
    echo "Installing Session Manager Plugin for macOS Apple Silicon..."
    PACKAGE="mac_arm64/sessionmanager-bundle.zip"
  elif [ "$ARCH" = "x86_64" ]; then
    # macOS Intel
    echo "Installing Session Manager Plugin for macOS Intel..."
    PACKAGE="mac/sessionmanager-bundle.zip"
  else
    echo "ERROR: Unsupported macOS architecture: $ARCH"
    exit 1
  fi

  curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/$PACKAGE" -o "/tmp/sessionmanager-bundle.zip"
  unzip -q /tmp/sessionmanager-bundle.zip -d /tmp

  echo ""
  echo "Installing plugin (requires sudo)..."
  sudo /tmp/sessionmanager-bundle/install -i /usr/local/sessionmanagerplugin -b /usr/local/bin/session-manager-plugin

  rm -rf /tmp/sessionmanager-bundle /tmp/sessionmanager-bundle.zip

else
  echo "ERROR: Unsupported operating system: $OS"
  echo "Please install manually: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
  exit 1
fi

echo ""
echo "=== Installation Complete ==="
echo ""

# Verify installation
if command -v session-manager-plugin &> /dev/null; then
  echo "Session Manager Plugin version:"
  session-manager-plugin --version
  echo ""
  echo "✓ Session Manager Plugin is installed and ready to use"
else
  echo "✗ WARNING: session-manager-plugin not found in PATH"
  echo "  You may need to restart your shell or add it to PATH manually"
  exit 1
fi
