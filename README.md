# Geocoding API

[![Build](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml/badge.svg)](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml)

Todo:
- Reconsider using protobuf library for json encoding (faster, but skips empty values, https://github.com/apple/swift-protobuf/issues/1171)
- include additional postal database http://download.geonames.org/export/zip/
- correctly implement iso2 county code filter
- GeoIP support + weighted results by distance
- Coordinates proximity search

## Docker

Docker Compose downloads the required GeoNames source files, builds the geocoding database in a persistent volume, and starts the API after preparation succeeds:

```bash
docker compose up --build
```

On a fresh volume, database preparation requires at least 6 GB of memory and takes around 25 minutes on a CPU with two Skylake-class cores. Loading the generated database before the API starts serving requests takes roughly another 5 minutes. Preparation logs are available from the `prepare-data` service.

The generated `database.bin` is stored in the `db_data` volume. Source archives and extracted text files are removed after a successful build. Later starts skip preparation and reuse the existing database:

```bash
docker compose down
docker compose up
```

To refresh the database from the latest GeoNames dumps, stop the API, explicitly rerun preparation, and start it again:

```bash
docker compose stop open-meteo
docker compose run --rm -e FORCE_REFRESH=1 prepare-data
docker compose up -d open-meteo
```

Running `docker compose down -v` deletes the database volume. The next start will download the source files and rebuild the database from scratch. When running the image without Compose, mount a prepared database at `/app/data/database.bin`.


## Installation on ubuntu 20.04
The standalone `geocodingapi` binary can run on any 64-bit linux with recent libc. Currently only basic installation instructions for ubuntu 22.04 are available.

```bash
apt install zip

wget https://github.com/open-meteo/geocoding-api/releases/download/0.1.1/geocoding-api_0.0.6_jammy_amd64.deb
dpkg -i geocoding-api_0.1.1_jammy_amd64.deb

mkdir /var/lib/geocoding-api/data
cd /var/lib/geocoding-api/data
mkdir zip
curl http://download.geonames.org/export/dump/allCountries.zip -o allCountries.zip
curl http://download.geonames.org/export/dump/alternateNamesV2.zip -o alternateNamesV2.zip
unzip allCountries.zip
unzip alternateNamesV2.zip

systemctl enable geocoding-api.service
systemctl start geocoding-api.service
systemctl status geocoding-api.service
```

Geonames data are parsed and processed during the first start, which requires some times and memor. At least 6GB RAM is required and it takes about 25 minutes on a CPU with 2 Skylake cores. Database loading takes about 5 minutes after that.

Additionally, nginx proxy should be used.

## Terms & Privacy
Open-Meteo APIs are free for open-source developer and non-commercial use. We do not restrict access, but ask for fair use.

If your application exceeds 10'000 requests per day, please contact us. We reserve the right to block applications and IP addresses that misuse our service.

For commercial use of Open-Meteo APIs, please contact us.

All data is provided as is without any warranty.

We do not collect any personal data. We do not share any personal information. We do not integrate any third party analytics, ads, beacons or plugins.

## Data License
API data are offered under Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)

You are free to share: copy and redistribute the material in any medium or format and adapt: remix, transform, and build upon the material.

Attribution: You must give appropriate credit, provide a link to the license, and indicate if changes were made. You may do so in any reasonable manner, but not in any way that suggests the licensor endorses you or your use.

You must include a link next to any location, Open-Meteo data are displayed like:

<a href="https://open-meteo.com/">Weather data by Open-Meteo.com</a>

NonCommercial: You may not use the material for commercial purposes.


## Source Code License
Open-Meteo is open-source under the GNU Affero General Public License Version 3 (AGPLv3) or any later version. You can [find the license here](LICENSE). Exceptions are third party source-code with individual licensing in each file.
