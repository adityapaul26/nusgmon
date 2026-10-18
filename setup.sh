#!/usr/bin/env bash
set -e

# colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

if [[ ! "$EUID" -eq 0 ]]; then
    die "Run this script as root user to install nusgmon."
    exit 1
fi

OS="$(uname -s)"
case "$OS" in
    Linux*)
        IS_LINUX=true
        IS_MACOS=false
        ;;
    Darwin*)
        IS_LINUX=false
        IS_MACOS=true
        ;;
    *)
        die "Unsupported operating system: $OS. nusgmon supports Linux and macOS."
        ;;
esac

if command -v getent &>/dev/null; then
    REAL_HOME=$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)
elif command -v dscl &>/dev/null; then
    REAL_HOME=$(dscl . -read "/Users/${SUDO_USER:-$USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
fi
[[ -z "$REAL_HOME" ]] && REAL_HOME=$(eval echo "~${SUDO_USER:-$USER}")

USER_SITE=""
if [[ -n "$SUDO_USER" ]]; then
    if [[ -d "$REAL_HOME/Library/Python" ]]; then
        LATEST_MACOS_SITE=$(find "$REAL_HOME/Library/Python" -maxdepth 4 -type d -name "site-packages" 2>/dev/null | sort -V | tail -n 1 || true)
        [[ -n "$LATEST_MACOS_SITE" ]] && USER_SITE="$LATEST_MACOS_SITE"
    elif [[ -d "$REAL_HOME/.local/lib" ]]; then
        LATEST_LINUX_SITE=$(find "$REAL_HOME/.local/lib" -maxdepth 4 -type d -name "site-packages" 2>/dev/null | sort -V | tail -n 1 || true)
        [[ -n "$LATEST_LINUX_SITE" ]] && USER_SITE="$LATEST_LINUX_SITE"
    fi
fi

# preflight checks
[[ -f nusgmon ]]         || die "nusgmon binary not found. Run this from the repo root."
[[ -f config.toml ]]     || die "config.toml not found. Run this from the repo root."

if [[ "$IS_LINUX" == "true" ]]; then
    [[ -f nusgmon.service ]] || die "nusgmon.service not found. Run this from the repo root."
elif [[ "$IS_MACOS" == "true" ]]; then
    [[ -f com.luckys1nghh.nusgmon.plist ]] || die "com.luckys1nghh.nusgmon.plist not found. Run this from the repo root."
fi

command -v python3 &>/dev/null || die "python3 is not installed."
if ! python3 -c "import psutil" 2>/dev/null; then
    if [[ -n "$USER_SITE" ]] && PYTHONPATH="$USER_SITE" python3 -c "import psutil" 2>/dev/null; then
        export PYTHONPATH="$USER_SITE"
    else
        die "psutil not installed. Run: pip install psutil"
    fi
fi

if [[ "$IS_LINUX" == "true" ]]; then
    if ! systemctl --version &>/dev/null; then
        die "systemd is not available on this system."
    fi
elif [[ "$IS_MACOS" == "true" ]]; then
    if ! command -v launchctl &>/dev/null; then
        die "launchctl is not available on this system."
    fi
fi

# interval prompt
while true; do
    read -rp "Enter record interval in seconds [default -> 3]: " _interval
    interval="${_interval:-3}"
    if [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
        break
    else
        warn "Invalid input. Enter a positive integer (e.g. 3)."
    fi
done

# install system wide
if [[ "$IS_LINUX" == "true" ]]; then
    SERVICE_DIR="/etc/systemd/system"
elif [[ "$IS_MACOS" == "true" ]]; then
    SERVICE_DIR="/Library/LaunchDaemons"
    PLIST_NAME="com.luckys1nghh.nusgmon.plist"
fi
BIN_PATH="/usr/local/bin/nusgmon"
ROOT_CONFIG_DIR="/etc/nusgmon"
USER_CONFIG_DIR="$REAL_HOME/.config/nusgmon"

info "Installing nusgmon.."
mkdir -p "$(dirname "$BIN_PATH")"
mkdir -p "$ROOT_CONFIG_DIR"
mkdir -p "$USER_CONFIG_DIR"
mkdir -p /var/lib/nusgmon

install -m 755 nusgmon "$BIN_PATH"

if [[ "$IS_LINUX" == "true" ]]; then
    install -m 644 nusgmon.service "$SERVICE_DIR/nusgmon.service"
elif [[ "$IS_MACOS" == "true" ]]; then
    install -m 644 "$PLIST_NAME" "$SERVICE_DIR/$PLIST_NAME"
fi

if [[ ! -f "$ROOT_CONFIG_DIR/config.toml" ]]; then
   install -m 644 config.toml "$ROOT_CONFIG_DIR/config.toml"
   if [[ "$IS_MACOS" == "true" ]]; then
       python3 -c "
with open('$ROOT_CONFIG_DIR/config.toml', 'r') as f:
    c = f.read()
c = c.replace(\"record_iface = ['wlp2s0', 'enp2s0']\", \"record_iface = ['en0', 'en1']\")
with open('$ROOT_CONFIG_DIR/config.toml', 'w') as f:
    f.write(c)
" 2>/dev/null || true
   fi
fi

if [[ ! -f "$USER_CONFIG_DIR/config.toml" ]]; then
   install -m 644 config.toml "$USER_CONFIG_DIR/config.toml"
   if [[ "$IS_MACOS" == "true" ]]; then
       python3 -c "
with open('$USER_CONFIG_DIR/config.toml', 'r') as f:
    c = f.read()
c = c.replace(\"record_iface = ['wlp2s0', 'enp2s0']\", \"record_iface = ['en0', 'en1']\")
with open('$USER_CONFIG_DIR/config.toml', 'w') as f:
    f.write(c)
" 2>/dev/null || true
   fi
fi

chmod 755 "$ROOT_CONFIG_DIR" "$USER_CONFIG_DIR" /var/lib/nusgmon
if [[ -n "$SUDO_USER" ]]; then
    chown -R "$SUDO_USER" "$USER_CONFIG_DIR" 2>/dev/null || true
    chown -R "$SUDO_USER" /var/lib/nusgmon 2>/dev/null || true
fi

# Pre-initialize database file so db queries work immediately
if [[ ! -f /var/lib/nusgmon/db.sqlite ]]; then
    python3 -c "
import sqlite3, os
conn = sqlite3.connect('/var/lib/nusgmon/db.sqlite')
conn.execute('''
CREATE TABLE IF NOT EXISTS data_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp INTEGER NOT NULL,
    bytes_sent INTEGER NOT NULL,
    bytes_recv INTEGER NOT NULL,
    iface TEXT DEFAULT \'all\'
)''')
conn.execute('CREATE INDEX IF NOT EXISTS idx_timestamp ON data_usage(timestamp)')
conn.commit()
conn.close()
os.chmod('/var/lib/nusgmon/db.sqlite', 0o666)
" 2>/dev/null || true
    if [[ -n "$SUDO_USER" ]]; then
        chown -R "$SUDO_USER" /var/lib/nusgmon 2>/dev/null || true
    fi
fi

if [[ "$IS_LINUX" == "true" ]]; then
    sed -i "s|^ExecStart=.*|ExecStart=$BIN_PATH record -w $interval|" "$SERVICE_DIR/nusgmon.service"

    systemctl daemon-reload
    systemctl enable --now nusgmon
    systemctl is-active --quiet nusgmon \
        && info "Service is running." \
        || warn "Service may not have started. Check: systemctl status nusgmon"
elif [[ "$IS_MACOS" == "true" ]]; then
    PYTHON_BIN="$(command -v python3)"
    python3 -c "
import plistlib, os
plist_path = '$SERVICE_DIR/$PLIST_NAME'
with open(plist_path, 'rb') as f:
    pl = plistlib.load(f)
pl['ProgramArguments'] = ['$PYTHON_BIN', '$BIN_PATH', 'record', '-w', '$interval']
user_site = '$USER_SITE'
if user_site:
    if 'EnvironmentVariables' not in pl:
        pl['EnvironmentVariables'] = {}
    pl['EnvironmentVariables']['PYTHONPATH'] = user_site
with open(plist_path, 'wb') as f:
    plistlib.dump(pl, f)
"
    launchctl unload -w "$SERVICE_DIR/$PLIST_NAME" 2>/dev/null || true
    launchctl load -w "$SERVICE_DIR/$PLIST_NAME"
    launchctl list com.luckys1nghh.nusgmon &>/dev/null \
        && info "Service is running." \
        || warn "Service may not have started. Check: sudo launchctl list com.luckys1nghh.nusgmon"
fi


# check for old path of nusgmon (~/.nusgmon)
if [ -d "$REAL_HOME/.nusgmon" ] && [ -f "$REAL_HOME/.nusgmon/db.sqlite" ]; then
	echo -e "\n\e[1;37mYou have $REAL_HOME/.nusgmon which takes your old data of your bandwidth usage\nAnd the new path for it is /var/lib/nusgmon\n\e[0m"
	read -p "Copy it to new path (/var/lib/nusgmon) ? [y/n]: " choice

	if [[ "$choice" == "y" ]]; then
		mkdir -p /var/lib/nusgmon
		chmod 755 /var/lib/nusgmon

		# force sqlite wal checkpoint to get full data in main DB file before copying
		python3 -c "import sqlite3; c=sqlite3.connect('$REAL_HOME/.nusgmon/db.sqlite'); c.execute('PRAGMA wal_checkpoint(TRUNCATE);'); c.close()"

		# now copy and set permissions nicely
		cp "$REAL_HOME/.nusgmon/db.sqlite" /var/lib/nusgmon/db.sqlite
		chmod 664 /var/lib/nusgmon/*
		if [[ -n "$SUDO_UID" && -n "$SUDO_GID" ]]; then
			chown -R "$SUDO_UID:$SUDO_GID" /var/lib/nusgmon 2>/dev/null || true
		fi

		echo
		info "Database file copied to new path."
	fi
        echo
fi

info "Done! Interval set to ${interval}s."
