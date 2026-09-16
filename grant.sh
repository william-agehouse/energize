#!/bin/bash
#
# Energize — optional one-time grant, so the app stops asking for your password.
#
# Read this before you run it. It is deliberately short and plain.
#
# It adds a rule permitting exactly two commands to run as root without a
# password: the switch that stops your Mac sleeping, and the one that puts it
# back. The arguments are spelled out in full and there are no wildcards, so
# nothing else is covered. The worst anyone could do with it is keep your Mac
# awake or let it sleep.
#
#   ./grant.sh            add the rule
#   ./grant.sh --remove   take it away again
#
# The app's "Stop asking for my password" button does not run this. It opens a
# Terminal window pointed at this file and steps back, so you read it, you type
# your own password, and the app itself never gets to write a sudoers rule.
#
# Why the fuss with a temporary file: a sudoers file containing a syntax error
# stops `sudo` working at all, and repairing it needs `sudo`. So the rule is
# written somewhere harmless first, checked with `visudo -c`, and only moved into
# place if that check passes. This script also refuses to edit /etc/sudoers
# itself — it only ever adds a separate file in /etc/sudoers.d.
#
set -euo pipefail

RULE_FILE=/etc/sudoers.d/energize
REMOVE=no
ACCOUNT=${SUDO_USER:-$(id -un)}

while [ $# -gt 0 ]; do
    case "$1" in
        --remove)  REMOVE=yes; shift ;;
        --account) ACCOUNT=${2:-}; shift 2 ;;
        *) echo "Unknown option '$1'. Use --remove, or --account NAME." >&2; exit 1 ;;
    esac
done

# Running as root makes `id -un` say "root", which would write a rule for the
# wrong account. A rule for root grants nothing new, so refuse instead.
if [ "$ACCOUNT" = "root" ]; then
    echo "Run this as yourself, not with sudo, or pass --account YOURNAME." >&2
    exit 1
fi

# Refuse to build a rule around an unusual account name rather than writing
# something unexpected into a sudoers file.
case "$ACCOUNT" in
    *[!A-Za-z0-9._-]*|"")
        echo "Unexpected characters in the account name '$ACCOUNT'. Stopping." >&2
        exit 1
        ;;
esac

# When the app calls this we are already root, and `sudo` would be pointless
# noise in the middle of a privileged run.
if [ "$(id -u)" = "0" ]; then AS_ROOT=""; else AS_ROOT="sudo"; fi

if [ "$REMOVE" = yes ]; then
    $AS_ROOT rm -f "$RULE_FILE"
    echo "Removed. Energize will ask for your password again."
    exit 0
fi

if ! $AS_ROOT grep -qE '^[#@]includedir[[:space:]]+/private/etc/sudoers.d' /etc/sudoers; then
    echo "This Mac's /etc/sudoers does not read /etc/sudoers.d, and this script" >&2
    echo "will not edit /etc/sudoers itself. Stopping; nothing was changed." >&2
    exit 1
fi

TEMP=$(mktemp /tmp/energize-sudoers.XXXXXX)
trap 'rm -f "$TEMP"' EXIT

cat > "$TEMP" <<RULE
# Installed by Energize. Delete this file, or run grant.sh --remove, to undo it.
# Exactly two commands, arguments in full, no wildcards.
$ACCOUNT ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
RULE

echo "Checking the rule before installing it..."
$AS_ROOT visudo -c -f "$TEMP" >/dev/null
echo "Syntax is good. Installing to $RULE_FILE"
$AS_ROOT install -o root -g wheel -m 0440 "$TEMP" "$RULE_FILE"

# Ask sudo whether it actually worked. Only meaningful when we are the account
# the rule was written for; as root the answer is always yes and proves nothing.
if [ -z "$AS_ROOT" ] || sudo -n -l /usr/bin/pmset -a disablesleep 1 >/dev/null 2>&1; then
    echo
    echo "Done. Energize will not ask for your password again."
    echo "To undo this at any time:  ./grant.sh --remove"
else
    echo "Installed, but sudo still wants a password. Inspect $RULE_FILE." >&2
    exit 1
fi
