#!/bin/bash
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

fail() {
    echo
    echo "::error::$1"
    exit 1
}

require_fixed() {
    local needle="$1"
    local file="$2"

    grep -Fq -- "$needle" "$file" ||
        fail "Required invariant missing from $file: $needle"
}

forbid_fixed() {
    local needle="$1"
    local file="$2"

    if grep -Fq -- "$needle" "$file"; then
        fail "Forbidden text found in $file: $needle"
    fi
}

echo "Checking UsageOwl custom-fork invariants..."

# ------------------------------------------------------------
# Identity / local Intel build
# ------------------------------------------------------------

require_fixed \
    'BUNDLE_ID="com.usageowl.app"' \
    app/build_app.sh

require_fixed \
    'swift build -c release --arch x86_64' \
    app/build_app.sh

forbid_fixed \
    'swift build -c release --arch arm64 --arch x86_64' \
    app/build_app.sh

# ------------------------------------------------------------
# Claude WebKit login preservation
# ------------------------------------------------------------

require_fixed \
    'static var store: WKWebsiteDataStore { .default() }' \
    app/Sources/UsageOwl/Services/WebSession.swift

require_fixed \
    'config.websiteDataStore = WebSession.store' \
    app/Sources/UsageOwl/Views/WebLoginView.swift

require_fixed \
    'guard service.id != WebService.claude.id else { return }' \
    app/Sources/UsageOwl/Views/SettingsView.swift

# Claude provider code itself must never initiate a sign-out.
forbid_fixed \
    'signOut(' \
    app/Sources/UsageOwl/Providers/ClaudeProvider.swift

# ------------------------------------------------------------
# ChatGPT + Claude + Antigravity
# ------------------------------------------------------------

FILTER='["codex", "claude", "antigravity"].contains($0.id)'

FILTER_COUNT="$(grep -F -c -- "$FILTER" app/Sources/UsageOwl/Views/MenuPopover.swift || true)"

if [ "$FILTER_COUNT" -lt 2 ]; then
    fail "ChatGPT/Claude/Antigravity popup filter is missing or incomplete."
fi

# Popup should not regain the old toggle section.
forbid_fixed \
    'menuBarSection' \
    app/Sources/UsageOwl/Views/MenuPopover.swift

require_fixed \
    'Section("Menu Bar")' \
    app/Sources/UsageOwl/Views/SettingsView.swift

# ------------------------------------------------------------
# IST / 12-hour display
# ------------------------------------------------------------

require_fixed \
    'TimeZone(identifier: "Asia/Kolkata")!' \
    app/Sources/UsageOwl/Services/Format.swift

require_fixed \
    'formatter.dateFormat = "h:mm a"' \
    app/Sources/UsageOwl/Services/Format.swift

# ------------------------------------------------------------
# Custom-fork updater
# ------------------------------------------------------------

require_fixed \
    'https://api.github.com/repos/RealRONiN/usageowl/releases/latest' \
    app/Sources/UsageOwl/Services/UpdateChecker.swift

forbid_fixed \
    'https://api.github.com/repos/usageowl/usageowl/releases/latest' \
    app/Sources/UsageOwl/Services/UpdateChecker.swift

# ------------------------------------------------------------
# Native reset notifications
# ------------------------------------------------------------

require_fixed \
    'resetWarningNotificationsEnabled' \
    app/Sources/UsageOwl/Services/UsageStore.swift

require_fixed \
    'resetCompletionNotificationsEnabled' \
    app/Sources/UsageOwl/Services/UsageStore.swift

require_fixed \
    'syncResetNotifications(' \
    app/Sources/UsageOwl/Services/Notifier.swift

require_fixed \
    'sendTestResetNotification()' \
    app/Sources/UsageOwl/Services/Notifier.swift

echo
echo "PASS: all custom-fork invariants are intact."
