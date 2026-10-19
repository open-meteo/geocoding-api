# Geocoding API

[![Build](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml/badge.svg)](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml)
[![Latest release](https://img.shields.io/github/v/release/open-meteo/geocoding-api)](https://github.com/open-meteo/geocoding-api/releases/latest)

Search GeoNames locations with the Open-Meteo geocoding service, written in Swift.

## Reporting bugs

[Open an issue](https://github.com/open-meteo/geocoding-api/issues) and include:

- The exact request URL and parameters.
- The expected result and actual response or error.
- Whether you used the hosted API or a self-hosted instance.
- For self-hosted instances: the release or commit, operating system, database source
  and date, and relevant logs.
- For incorrect location data: the location name and GeoNames ID, when available.

Search existing issues before opening a new one.

## Contributing

Install the Swift version pinned in [`.swift-version`](.swift-version), then run:

```bash
swift build
swift test
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) for test guidance and pull-request instructions.
Consult the [database format reference](docs/database-format.md) when working on
storage or search indexes.

## Self-hosting

Choose an installation method:

- [Debian package](docs/self-hosting.md#debian-installation): install the executable
  and a matching prebuilt database from a published release.
- [Docker Compose](docs/self-hosting.md#docker-compose): build the image, prepare the
  database volume, and start the service on port 8080.
- [Build from source](docs/self-hosting.md#building-from-source): download GeoNames
  data and build the executable and database with Swift.

Prepare `data/database-v1.bin` before starting the service. Paths are relative to the
process working directory. Verify the database before deployment and restart the
service after replacing it. See [rebuilding and upgrading](docs/self-hosting.md#rebuilding-and-upgrading)
for replacement and compatibility instructions.

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
