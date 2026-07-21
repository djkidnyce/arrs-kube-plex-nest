#!/bin/sh
# Offline tests for files/scripts/sab-seed.sh
# Usage: sh tests/test_sab_seed.sh
set -u
DIR="$(mktemp -d)"
SCRIPT="$DIR/seed.sh"
INI="$DIR/config/sabnzbd.ini"
mkdir -p "$DIR/config"
sed "s|/config/sabnzbd.ini|$INI|g" "$(dirname "$0")/../files/scripts/sab-seed.sh" > "$SCRIPT"

export SEED_ENABLED=true ENABLE_HTTPS=0 INET_EXPOSURE=4
export HOST_WHITELIST="sabnzbd,sabnzbd.media,sabnzbd.media.svc,sabnzbd.media.svc.cluster.local"

fails=0
ok()   { echo "PASS  $1"; }
bad()  { echo "FAIL  $1"; fails=$((fails + 1)); }
has()  { grep -qE "$1" "$INI" && ok "$2" || bad "$2"; }

# 1. fresh install writes a usable config
rm -f "$INI"; sh "$SCRIPT" > /dev/null
has '^\[misc\]'            "fresh install: [misc] section written"
has '^inet_exposure = 4'   "fresh install: inet_exposure set"
has '^enable_https = 0'    "fresh install: enable_https set"
has '^host_whitelist = sabnzbd,' "fresh install: whitelist seeded"

# 2. existing config: values replaced, others preserved, trailing comma normalised
cat > "$INI" <<'INI'
__version__ = 19
[misc]
enable_https_verification = 1
enable_https = 1
inet_exposure = 0
host_whitelist = download,
username = keepme
INI
sh "$SCRIPT" > /dev/null
has '^enable_https = 0'              "existing: enable_https replaced"
has '^enable_https_verification = 1' "existing: similar key untouched"
has '^inet_exposure = 4'             "existing: inet_exposure replaced"
has '^username = keepme'             "existing: unrelated key preserved"
grep -q 'host_whitelist = download,sabnzbd,' "$INI" \
  && ok "existing: whitelist merged, empty entry dropped" \
  || bad "existing: whitelist merged, empty entry dropped"

# 3. idempotent
before="$(grep '^host_whitelist' "$INI")"
sh "$SCRIPT" > /dev/null
[ "$before" = "$(grep '^host_whitelist' "$INI")" ] \
  && ok "idempotent: second run changes nothing" \
  || bad "idempotent: second run changes nothing"

# 4. missing key is inserted
grep -v '^inet_exposure' "$INI" > "$INI.tmp" && mv "$INI.tmp" "$INI"
sh "$SCRIPT" > /dev/null
has '^inet_exposure = 4' "missing key inserted into [misc]"

# 5. disabled seeding is a no-op
cp "$INI" "$INI.bak"
SEED_ENABLED=false sh "$SCRIPT" > /dev/null
cmp -s "$INI" "$INI.bak" && ok "SEED_ENABLED=false leaves config alone" \
                         || bad "SEED_ENABLED=false leaves config alone"

rm -rf "$DIR"
echo
[ "$fails" -eq 0 ] && { echo "ALL SEED TESTS PASSED"; exit 0; }
echo "$fails FAILURES"; exit 1
