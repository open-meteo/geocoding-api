# Self-hosting

Choose [Debian installation](#debian-installation), [Docker Compose](#docker-compose), or [building from source](#building-from-source).

Use an executable and database from the same release. The service reads `data/database-v1.bin` relative to its working directory. Prepare and verify the database before starting the service, and restart after replacing it.

## Debian installation

Download a matching package and database for Ubuntu 22.04 amd64. Set `RELEASE_TAG` to `latest` or a specific published [release](https://github.com/open-meteo/geocoding-api/releases), such as `0.6.0`. Run in Bash, then continue with [first installation](#first-installation) or [upgrade](#upgrading-with-little-interruption) in the same shell.

```bash
set -euo pipefail

sudo apt-get update
sudo apt-get install -y ca-certificates curl zstd

RELEASE_TAG='latest'
if [ "$RELEASE_TAG" = latest ]; then
  RELEASE_PAGE=$(curl --fail --silent --show-error --location --head --retry 3 --output /dev/null --write-out '%{url_effective}' 'https://github.com/open-meteo/geocoding-api/releases/latest')
  RELEASE_TAG="${RELEASE_PAGE##*/}"
fi
DEB_ASSET="geocoding-api_${RELEASE_TAG}_jammy_amd64.deb"
RELEASE_URL="https://github.com/open-meteo/geocoding-api/releases/download/${RELEASE_TAG}"

mkdir -p "geocoding-${RELEASE_TAG}"
cd "geocoding-${RELEASE_TAG}"
curl --fail --location --retry 3 "${RELEASE_URL}/${DEB_ASSET}" -o "$DEB_ASSET"
curl --fail --location --retry 3 "${RELEASE_URL}/database-v1.bin.zst" -o database-v1.bin.zst
curl --fail --location --retry 3 "${RELEASE_URL}/database-v1.bin.zst.sha256" -o database-v1.bin.zst.sha256
sha256sum --check database-v1.bin.zst.sha256
```

### First installation

Install the package, verify the database, then start the service.

```bash
sudo mkdir -p /var/lib/geocoding-api/data
sudo zstd -d database-v1.bin.zst -o /var/lib/geocoding-api/data/database-v1.bin.new

# Prevent package installation from starting the service before verification.
sudo systemctl mask --runtime --now geocoding-api.service
sudo apt-get install -y "./${DEB_ASSET}"

sudo chmod 644 /var/lib/geocoding-api/data/database-v1.bin.new
sudo -u geocoding-api /usr/local/bin/geocoding-api verify-database \
  --database /var/lib/geocoding-api/data/database-v1.bin.new
sudo mv /var/lib/geocoding-api/data/database-v1.bin.new \
  /var/lib/geocoding-api/data/database-v1.bin

sudo systemctl unmask --runtime geocoding-api.service
sudo systemctl enable --now geocoding-api.service
sudo systemctl status geocoding-api.service
```

If verification fails, fix the error before unmasking the service.

The service runs from `/var/lib/geocoding-api` and listens on `127.0.0.1:8082`. Point your reverse proxy there, or change `API_BIND` in `/etc/default/geocoding-api.env` and restart.

### Upgrading with little interruption

Keep serving during installation and verification; interrupt requests only for the final restart. Mask **without `--now`** to suppress the package's automatic restart.

```bash
DATABASE_DIR='/var/lib/geocoding-api/data'

sudo zstd -d database-v1.bin.zst -o "${DATABASE_DIR}/database-v1.bin.new"
sudo chmod 644 "${DATABASE_DIR}/database-v1.bin.new"

# No --now: the old process must keep running.
sudo systemctl mask --runtime geocoding-api.service
sudo apt-get install -y "./${DEB_ASSET}"
sudo -u geocoding-api /usr/local/bin/geocoding-api verify-database \
  --database "${DATABASE_DIR}/database-v1.bin.new"
sudo mv "${DATABASE_DIR}/database-v1.bin.new" "${DATABASE_DIR}/database-v1.bin"

# The brief interruption starts at restart.
sudo systemctl unmask --runtime geocoding-api.service
sudo systemctl enable geocoding-api.service
sudo systemctl restart geocoding-api.service
sudo systemctl status geocoding-api.service
```

If installation or verification fails, resolve it before unmasking. A masked service cannot restart after a crash.

## Docker Compose

Install Docker with Compose, then run these commands from the repository root. First [download and extract the source data](#download-source-data) into `data/`. Copy the TSV files into the Compose volume, build and verify the database, then start:

```bash
docker compose build
docker compose run --rm --entrypoint /bin/sh -v "$PWD/data:/sources:ro" open-meteo -c \
  'cp /sources/allCountries.txt /sources/alternateNamesV2.txt /app/data/'
docker compose run --rm open-meteo build-database
docker compose run --rm open-meteo verify-database
docker compose up -d
curl 'http://localhost:8080/v1/search?name=Berlin&count=5&language=en'
```

The [Compose configuration](../docker-compose.yml) stores data in the `db_data` named volume and publishes port 8080. Keep this volume when recreating containers. The [Dockerfile](../Dockerfile) uses `/app` as its working directory.

To use a prebuilt database, download and check the matching release assets as described above, then decompress `database-v1.bin` into your local `data/` directory. Copy it into the volume in place of the TSV files and skip `build-database`:

```bash
docker compose build
docker compose run --rm --entrypoint /bin/sh -v "$PWD/data:/sources:ro" open-meteo -c \
  'cp /sources/database-v1.bin /app/data/'
docker compose run --rm open-meteo verify-database
docker compose up -d
```

Use this copy procedure for initial setup. Stop existing containers before replacing a database in the volume, then verify it before starting them again.

## Building from source

Install Swift 6.4 (see [`.swift-version`](../.swift-version)), `curl`, and `unzip`. Run from the repository root. Download and extract `allCountries.txt` and `alternateNamesV2.txt` into `data/`, then build the executable and database:

### Download source data

```bash
mkdir -p data
curl -fL https://download.geonames.org/export/dump/allCountries.zip -o data/allCountries.zip
curl -fL https://download.geonames.org/export/dump/alternateNamesV2.zip -o data/alternateNamesV2.zip
unzip -o data/allCountries.zip -d data
unzip -o data/alternateNamesV2.zip -d data
```

### Build and start

```bash
swift build -c release --product Run
.build/release/Run build-database
.build/release/Run verify-database
.build/release/Run serve --env production --hostname 0.0.0.0 --port 8080
```

All default paths are relative to the process working directory. The builder and service both use `data/database-v1.bin`. Startup opens this prebuilt file; a missing or incompatible file makes startup fail with instructions to build and verify it. Source files being present does not trigger an automatic build.

Check the running service:

```bash
curl 'http://localhost:8080/v1/search?name=Berlin&count=5&language=en'
```

## Rebuilding and upgrading

Run these commands from the repository root to rebuild an existing database:

```bash
.build/release/Run build-database --force
.build/release/Run verify-database --database data/database-v1.bin
```

Format version 1 is the initial supported format. Earlier implementation experiments and the old protobuf `database.bin` are not supported; rebuild from the source TSV files rather than renaming an old database. Normalization and scoring versions are also checked at open. Restart the service after publishing a replacement so it opens the new immutable file.
