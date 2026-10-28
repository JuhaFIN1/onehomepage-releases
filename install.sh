#!/usr/bin/env bash
# One Homepage: installs a small Debian 13 container on this Proxmox host and puts the latest official release in it.
# A BluexDEV account (auth.selaa.fi) and a licence key are required to keep using it: licence keys are free for now,
# but the pricing may change in the future. The first 7 days work without one.
# Run as root in the Proxmox shell:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/JuhaFIN1/onehomepage-releases/main/install.sh)"
# Optional overrides: CTID=120 STORAGE=local-zfs BRIDGE=vmbr0 CHANNEL=dev DEBIAN=13 bash install.sh
# The release is checked against the publisher's Ed25519 signature (public key below) before anything is installed.
# Updates later come from the same place, from Settings -> Updates.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root in the Proxmox shell." >&2; exit 1; }
command -v pct >/dev/null || { echo "This must run on a Proxmox VE host (pct not found)." >&2; exit 1; }

REPO=JuhaFIN1/onehomepage-releases
CTID="${CTID:-$(pvesh get /cluster/nextid)}"
BRIDGE="${BRIDGE:-vmbr0}"
STORAGE="${STORAGE:-$(pvesm status --content rootdir | awk 'NR>1{print $1; exit}')}"
TPLSTORE="${TPLSTORE:-$(pvesm status --content vztmpl | awk 'NR>1{print $1; exit}')}"
CHANNEL="${CHANNEL:-stable}"

echo ">> One Homepage: CT $CTID, rootfs on $STORAGE, templates on $TPLSTORE, bridge $BRIDGE, channel $CHANNEL"
pveam update >/dev/null
DEBIAN="${DEBIAN:-13}"
TPL="$(pveam available --section system | awk '{print $2}' | grep "^debian-$DEBIAN-standard" | sort -V | tail -1 || true)"
if [ -z "$TPL" ] && [ "$DEBIAN" = 13 ]; then
  echo "!! No Debian 13 template offered by this Proxmox yet; using Debian 12 instead." >&2
  TPL="$(pveam available --section system | awk '{print $2}' | grep '^debian-12-standard' | sort -V | tail -1)"
fi
[ -n "$TPL" ] || { echo "No Debian template found (pveam update failed?)." >&2; exit 1; }
pveam list "$TPLSTORE" | grep -q "$TPL" || pveam download "$TPLSTORE" "$TPL"

pct create "$CTID" "$TPLSTORE:vztmpl/$TPL" \
  --hostname onehomepage --cores 1 --memory 256 --swap 128 \
  --rootfs "$STORAGE:2" --net0 "name=eth0,bridge=$BRIDGE,ip=dhcp" \
  --unprivileged 1 --onboot 1 --features nesting=1
pct start "$CTID"
for i in $(seq 1 30); do pct exec "$CTID" -- hostname -I 2>/dev/null | grep -q '[0-9]' && break; sleep 1; done

cat > /tmp/oh-setup.sh <<'EOS'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
REPO="$1"; CHANNEL="$2"
apt-get update -qq
apt-get install -y -qq ca-certificates curl tzdata openssl unattended-upgrades >/dev/null
# Debian security updates install themselves (the helper in Settings can also run a full update and cleanup)
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' > /etc/apt/apt.conf.d/20auto-upgrades
ln -sf /usr/share/zoneinfo/Europe/Helsinki /etc/localtime

# the publisher's public key: every release is checked against it
cat > /root/release_pub.pem <<'PEM'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAg2ZVstYAgvpgkbBQ4G4wkAEQR2seq17Bm1vsJ3g5/po=
-----END PUBLIC KEY-----
PEM

id onehomepage >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /opt/onehomepage onehomepage
install -d -m 750 -o root -g onehomepage /opt/onehomepage /opt/onehomepage/assets /etc/onehomepage
install -d -m 700 -o onehomepage -g onehomepage /opt/onehomepage/var /opt/onehomepage/var/update

# newest release of the channel
if [ "$CHANNEL" = dev ]; then
  JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=1")
else
  JSON=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest")
fi
VER=$(printf '%s' "$JSON" | grep -m1 '"tag_name"' | sed -E 's/.*"v?([^"]+)".*/\1/')
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "No release found yet in $REPO (try again later)." >&2; exit 1; }
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) echo "unsupported architecture" >&2; exit 1 ;; esac

STAGE=/opt/onehomepage/var/update/$VER
install -d -m 700 "$STAGE"
for f in checksums.txt checksums.txt.sig "onehomepage-$VER-linux-$ARCH.tar.gz" "onehomepage-$VER-assets.tar.gz"; do
  echo ">> downloading $f"
  curl -fsSL -o "$STAGE/$f" "https://github.com/$REPO/releases/download/v$VER/$f"
done
openssl pkeyutl -verify -pubin -inkey /root/release_pub.pem -rawin -in "$STAGE/checksums.txt" -sigfile "$STAGE/checksums.txt.sig" >/dev/null \
  || { echo "The signature does not match: not an official release. Nothing was installed." >&2; exit 1; }
(cd "$STAGE" && grep -E " [ *]onehomepage-$VER-(linux-$ARCH|assets)\.tar\.gz\$" checksums.txt | sha256sum -c - >/dev/null) \
  || { echo "Checksum mismatch. Nothing was installed." >&2; exit 1; }

# the update helper and the configuration come from the (now verified) assets archive
TMP=$(mktemp -d)
tar --no-same-owner -xzf "$STAGE/onehomepage-$VER-assets.tar.gz" -C "$TMP"
A="$TMP/onehomepage-assets"
bash "$A/deploy/install-updater.sh"
mkdir -p /opt/onehomepage/deploy && cp -r "$A/deploy/." /opt/onehomepage/deploy/
[ -f /etc/onehomepage/config.yaml ] || install -m 640 -o root -g onehomepage "$A/deploy/config.example.yaml" /etc/onehomepage/config.yaml
rm -rf "$TMP"

cat > /etc/systemd/system/onehomepage.service <<'CFG'
[Unit]
Description=One Homepage
After=network-online.target
Wants=network-online.target

[Service]
User=onehomepage
Group=onehomepage
WorkingDirectory=/opt/onehomepage
EnvironmentFile=-/etc/onehomepage/env
ExecStart=/opt/onehomepage/onehomepage -config /etc/onehomepage/config.yaml -data /opt/onehomepage/var -assets /opt/onehomepage/assets -env /dev/null
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/opt/onehomepage/var
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
MemoryMax=192M

[Install]
WantedBy=multi-user.target
CFG
systemctl daemon-reload
systemctl enable onehomepage >/dev/null 2>&1

# hand the verified release to the helper: it installs the files and starts the service
echo "$VER" > /opt/onehomepage/var/update/ready
chown onehomepage:onehomepage /opt/onehomepage/var/update/ready
for i in $(seq 1 90); do
  sleep 1
  if curl -fsS http://127.0.0.1/api/health 2>/dev/null | grep -q "\"version\":\"$VER\""; then echo ">> One Homepage $VER is running"; exit 0; fi
done
echo "The service did not answer in time. See: journalctl -u onehomepage -u onehomepage-update" >&2
exit 1
EOS
pct push "$CTID" /tmp/oh-setup.sh /root/oh-setup.sh
rm -f /tmp/oh-setup.sh
pct exec "$CTID" -- bash /root/oh-setup.sh "$REPO" "$CHANNEL"
pct exec "$CTID" -- rm -f /root/oh-setup.sh

IP="$(pct exec "$CTID" -- hostname -I | awk '{print $1}')"
echo
echo "=============================================="
echo " One Homepage is ready. Container $CTID."
echo " Open: http://$IP"
echo " Tip: reserve this address in your router (DHCP reservation)."
echo " First sign-in: the setup code is in the container:"
echo "   pct exec $CTID -- cat /opt/onehomepage/var/setup_code.txt"
echo " The first person to sign in with that code becomes the owner."
echo
echo " REQUIRED: a free BluexDEV account and a licence key (the first 7 days work without them)."
echo "   Start here, all steps in order: https://auth.selaa.fi/start/onehomepage"
echo "   1. Create your account and confirm your email:"
echo "      https://auth.selaa.fi/bluex-portal-2026-login/create-account?app=onehomepage"
echo "   2. In One Homepage open Settings -> Link to account, then approve the code at:"
echo "      https://auth.selaa.fi/device"
echo "      Your licence key is created for you and shows in your account."
echo " Licence keys are free for now, but the pricing may change in the future."
echo "=============================================="
