#!/bin/sh
set -eu

DATA_DIR=/app/data
GEONAMES_DUMP_URL=${GEONAMES_DUMP_URL:-https://download.geonames.org/export/dump}
FORCE_REFRESH=${FORCE_REFRESH:-0}
DATABASE_FILE="$DATA_DIR/database.bin"

mkdir -p "$DATA_DIR"

exec 9>"$DATA_DIR/.prepare.lock"
if ! flock -n 9; then
    echo "Another database preparation process is already using $DATA_DIR." >&2
    exit 1
fi

find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d -name '.prepare.*' -exec rm -rf {} +

if [ -f "$DATABASE_FILE" ] && [ "$FORCE_REFRESH" != "1" ]; then
    echo "Geocoding database already exists; skipping preparation."
    exit 0
fi

WORK_DIR=$(mktemp -d "$DATA_DIR/.prepare.XXXXXX")
ALL_COUNTRIES_FILE="$DATA_DIR/allCountries.txt"
ALTERNATE_NAMES_FILE="$DATA_DIR/alternateNamesV2.txt"

cleanup() {
    rm -f \
        "$ALL_COUNTRIES_FILE" \
        "$ALL_COUNTRIES_FILE.tmp" \
        "$ALTERNATE_NAMES_FILE" \
        "$ALTERNATE_NAMES_FILE.tmp"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

download() {
    url=$1
    destination=$2
    echo "Downloading $url"
    curl --fail --location --retry 5 --retry-all-errors --output "$destination.part" "$url"
    mv "$destination.part" "$destination"
}

extract() {
    archive=$1
    entry=$2
    destination=$3
    echo "Extracting $entry"
    unzip -p "$archive" "$entry" > "$destination.tmp"
    test -s "$destination.tmp"
    mv "$destination.tmp" "$destination"
}

download "$GEONAMES_DUMP_URL/allCountries.zip" "$WORK_DIR/allCountries.zip"
download "$GEONAMES_DUMP_URL/alternateNamesV2.zip" "$WORK_DIR/alternateNamesV2.zip"
extract "$WORK_DIR/allCountries.zip" allCountries.txt "$ALL_COUNTRIES_FILE"
extract "$WORK_DIR/alternateNamesV2.zip" alternateNamesV2.txt "$ALTERNATE_NAMES_FILE"

echo "Building geocoding database. This can take around 25 minutes and requires at least 6 GB of memory."
/app/PrepareDatabase
chown vapor:vapor "$DATABASE_FILE"

cleanup
trap - EXIT INT TERM
echo "Geocoding database preparation complete."
