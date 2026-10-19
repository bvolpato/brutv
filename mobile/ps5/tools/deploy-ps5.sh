#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Explicit FTP staging for a directory-title loader. Never launches a title.
set -euo pipefail
usage() {
    echo 'usage: deploy-ps5.sh CURRENT_PS5_IP [FTP_PORT=2121]'
    echo 'Stages a new PPSA99241 directory title. Refuses an existing title.'
}
if [[ ${1:-} == --help && $# == 1 ]]; then usage; exit 0; fi
if [[ $# -lt 1 || $# -gt 2 ]]; then usage >&2; exit 2; fi
host=$1
port=${2:-2121}
[[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo 'Pass the current IPv4 address, not a URL' >&2; exit 2; }
IFS=. read -r a b c d <<< "$host"
for octet in "$a" "$b" "$c" "$d"; do
    if [[ $octet != 0 && $octet == 0* ]] || (( 10#$octet > 255 )); then
        echo 'Invalid IPv4 address' >&2
        exit 2
    fi
done
if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port == 0 || 10#$port > 65535 )); then
    echo 'Invalid FTP port' >&2
    exit 2
fi
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
title=$(jq -er '.titleId | select(test("^PPSA[0-9]{5}$"))' "$root/sce_sys/param.json")
app="$root/build/ps5/title/$title"
[[ -s $app/eboot.bin && -s $app/sce_sys/param.json ]] || { echo 'Build the title first' >&2; exit 2; }
command -v curl >/dev/null
# FTP2121 is the configured console service. No payload-loader port is assumed.
# Credentials may be supplied through CURL_HOME/.netrc. A failed or inaccessible
# listing is a blocker; the script never interprets failure as an empty folder.
options=(--fail --show-error --silent --netrc-optional --connect-timeout 10 --max-time 120)
listing=$(curl "${options[@]}" --list-only "ftp://$host:$port/data/homebrew/") || {
    echo 'Cannot verify /data/homebrew. No files were sent.' >&2; exit 2;
}
while IFS= read -r entry; do
    entry=${entry%$'\r'}
    entry=${entry%/}
    if [[ ${entry##*/} == "$title" || ${entry##*/} == "$title.ffpkg" || ${entry##*/} == "$title.ffpfsc" ]]; then
        echo "Destination $title already exists. No overwrite is supported; no files were sent." >&2
        exit 2
    fi
done <<< "$listing"
while IFS= read -r -d '' file; do
    relative=${file#"$app/"}
    [[ $relative =~ ^[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*$ ]] || {
        echo "Unsafe FTP path: $relative" >&2; exit 2;
    }
    curl "${options[@]}" --ftp-create-dirs --upload-file "$file" \
        --quote "-SITE CHMOD 777 /data/homebrew/$title/$relative" \
        "ftp://$host:$port/data/homebrew/$title/$relative"
done < <(find "$app" -type f -print0 | sort -z)
# The reference directory-title loader requires open modes on directories too.
while IFS= read -r -d '' directory; do
    relative=${directory#"$app"}
    curl "${options[@]}" --quote "SITE CHMOD 777 /data/homebrew/$title$relative" \
        --list-only "ftp://$host:$port/data/homebrew/$title/" >/dev/null
done < <(find "$app" -type d -print0)
printf 'Staged %s at /data/homebrew/%s. No launch or system changes were performed.\n' "$title" "$title"
