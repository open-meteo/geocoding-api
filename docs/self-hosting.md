# Self-hosting

Choose [Debian installation](#debian-installation), [Docker Compose](#docker-compose),
or [building from source](#building-from-source).

Use an executable and database from the same release. The service reads
`data/database-v1.bin` relative to its working directory. Prepare and verify the database
before starting the service, and restart after replacing it.

The service uses Vapor `5.0.0-beta.4`. This beta's HTTP server does not yet wire up
response compression; configure gzip at your reverse proxy if needed. The previous
Vapor 4 pipelining toggle is also no longer exposed by the server adapter.
The existing `serve --env`, `--hostname`, `--port`, and `--bind` (`-b`) options remain
available, as do `VAPOR_ENV` and `LOG_LEVEL`.

## Debian installation

Download the Debian package, `database-v1.bin.zst`, and `database-v1.bin.zst.sha256`
from the same published [release](https://github.com/open-meteo/geocoding-api/releases).
Choose a release that includes all three assets.

For an Ubuntu 22.04 amd64 server, download all three assets from the same published
release. Replace the example tag below with the desired release tag; `DEB_ASSET` must
match the package filename shown on that release. Draft releases are not publicly
available through these download URLs.

Run the following in Bash. The commands stop on failure and keep the service stopped
until the new database passes verification:

```bash
set -euo pipefail

RELEASE_TAG='0.5.0-alpha.1'
DEB_ASSET="geocoding-api_${RELEASE_TAG}_jammy_amd64.deb"
RELEASE_URL="https://github.com/open-meteo/geocoding-api/releases/download/${RELEASE_TAG}"

sudo apt-get update
sudo apt-get install -y ca-certificates curl zstd

mkdir -p "geocoding-${RELEASE_TAG}"
cd "geocoding-${RELEASE_TAG}"
curl --fail --location --retry 3 "${RELEASE_URL}/${DEB_ASSET}" -o "$DEB_ASSET"
curl --fail --location --retry 3 "${RELEASE_URL}/database-v1.bin.zst" -o database-v1.bin.zst
curl --fail --location --retry 3 "${RELEASE_URL}/database-v1.bin.zst.sha256" -o database-v1.bin.zst.sha256
sha256sum --check database-v1.bin.zst.sha256

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

If installation or verification fails, resolve the failure before unmasking and starting
the service. For upgrades, retain the previous package and database together for rollback.
The final rename replaces the file atomically instead of overwriting an existing mapping.

The package installs the executable at `/usr/local/bin/geocoding-api` and the
[`systemd unit`](../build/geocoding-api.service) uses `/var/lib/geocoding-api` as its working
directory. The default configuration in `/etc/default/geocoding-api.env` listens on
`127.0.0.1:8082` in production mode. Configure a reverse proxy for that address or change
`API_BIND`, then restart the service.

To build the database on the server instead, place both source TSVs in
`/var/lib/geocoding-api/data/`, grant the `geocoding-api` account write access to that
directory, and run `build-database` followed by `verify-database` as that user from
`/var/lib/geocoding-api` before starting the service. Prebuilt deployments do not need
the source TSV files.

## Docker Compose

Install Docker with Compose, then run these commands from the repository root.
First [download and extract the source data](#download-source-data) into `data/`.
Copy the TSV files into the Compose volume, build and verify the database, then start:

```bash
docker compose build
docker compose run --rm --entrypoint /bin/sh -v "$PWD/data:/sources:ro" open-meteo -c \
  'cp /sources/allCountries.txt /sources/alternateNamesV2.txt /app/data/'
docker compose run --rm open-meteo build-database
docker compose run --rm open-meteo verify-database
docker compose up -d
curl 'http://localhost:8080/v1/search?name=Berlin&count=5&language=en'
```

The [Compose configuration](../docker-compose.yml) stores data in the `db_data` named
volume and publishes port 8080. Keep this volume when recreating containers.
The [Dockerfile](../Dockerfile) uses `/app` as its working directory.

To use a prebuilt database, download and check the matching release assets as described
above, then decompress `database-v1.bin` into your local `data/` directory. Copy it into
the volume in place of the TSV files and skip `build-database`:

```bash
docker compose build
docker compose run --rm --entrypoint /bin/sh -v "$PWD/data:/sources:ro" open-meteo -c \
  'cp /sources/database-v1.bin /app/data/'
docker compose run --rm open-meteo verify-database
docker compose up -d
```

Use this copy procedure for initial setup. Stop existing containers before replacing
a database in the volume, then verify it before starting them again.

## Building from source

Install Swift 6.4 (see [`.swift-version`](../.swift-version)), `curl`, and `unzip`.
On macOS, version 26.2 or later is required.
Run from the repository root. Download and extract `allCountries.txt` and
`alternateNamesV2.txt` into `data/`, then build the executable and database:

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

All default paths are relative to the process working directory. The builder and service
both use `data/database-v1.bin`. Startup opens this prebuilt file; a missing or incompatible
file makes startup fail with instructions to build and verify it. Source files being present
does not trigger an automatic build.

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

Format version 1 is the initial supported format. Earlier implementation experiments and
the old protobuf `database.bin` are not supported; rebuild from the source TSV files rather
than renaming an old database. Normalization and scoring versions are also checked at open.
Restart the service after publishing a replacement so it opens the new immutable file.
