# Geocoding API

[![Build](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml/badge.svg)](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml)

Todo:
- Reconsider using protobuf library for json encoding (faster, but skips empty values, https://github.com/apple/swift-protobuf/issues/1171)
- prepare licensing, release as open-source
- blog anouncement
- include additional postal database http://download.geonames.org/export/zip/
- correctly implement iso2 county code filter
- GeoIP support + weighted results by distance
- Coordinates proximity search


## Installation on ubuntu 20.04
The standalone `geocodingapi` binary can run on any 64-bit linux with recent libc. Currently only basic installation instructions for ubuntu 20.04 are available. Later Docker and others can be provided.

```bash
api install zip
useradd --user-group --create-home --system --skel /dev/null --home-dir /app geocoding
curl https://github.com/open-meteo/geocoding-api/releases/download/0.0.10/geocodingapi-ubuntu-20.04.gz | gunzip > /app/geocodingapi
chmod +x /app/geocodingapi
mkdir /app/data
cd /app/data
mkdir zip
curl http://download.geonames.org/export/dump/allCountries.zip -o allCountries.zip
curl http://download.geonames.org/export/dump/alternateNames.zip -o alternateNames.zip
curl http://download.geonames.org/export/zip/allCountries.zip -o zip/allCountries.zip
unzip allCountries.zip
unzip alternateNames.zip
cd zip; unzip allCountries.zip; cd ..

systemctl enable geocoding8080
systemctl start geocoding8080
systemctl status geocoding8080
```

- Create systemd service unit at `/etc/systemd/system/geocoding8080.service`
``
[Unit]
Description = Run geocoding API on port 8080

[Service]
Type=simple
User=geocoding
Group=geocoding
WorkingDirectory=/app
ExecStart=/app/geocodingapi serve -b 127.0.0.1:8080 --env production
Restart=always
RestartSec=1

[Install]
WantedBy = multi-user.target
``

Additionall nginx proxy should be used