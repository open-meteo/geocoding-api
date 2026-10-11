# Geocoding API

[![Build](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml/badge.svg)](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml)

Todo:

- Reconsider using the protobuf library for JSON encoding (faster, but skips empty values; see [swift-protobuf#1171](https://github.com/apple/swift-protobuf/issues/1171)).
- Include the additional [GeoNames postal-code database](https://download.geonames.org/export/zip/). Postal codes present in `alternateNamesV2.txt` are already indexed.
- Add GeoIP support and optionally weight results by distance.
- Add coordinate proximity search. The packed record layout stores coordinates in each location record,
  but a spatial index and API semantics still need to be designed.

ISO-2 country filtering is implemented inside the packed search traversal, before top-K selection.

## Database build

Use Swift 6.4, as pinned in `.swift-version` and the build images. The package
uses the experimental `Lifetimes` feature; `Package.swift` declares tools version 6.3.

The service uses `data/database-v1.bin`, a versioned, sectioned binary database read with
`mmap`. Locations are stored as fixed 64-byte records. Search names are stored
once per language/index in packed radix tries, with shared posting lists for matching
locations. Global queries traverse the radix directly; country and administrative-area
queries use sparse ordinal views over the same names. Binned segment-tree rank bounds let
top-K search skip ranges that cannot improve the result. Startup does not decode the full
dataset into Swift objects.

### Memory-mapped file format

`database-v1.bin` is a little-endian, self-describing container. All integers are stored
little-endian, `f32` values use their IEEE 754 bit pattern, and offsets are relative to the
start of the referenced section unless stated otherwise. Each section starts at a 4096-byte
file boundary; alignment padding is zero-filled and is not part of the section length or
hash.

The first 4096 bytes are the header:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | 8 bytes | Magic `GEOCDV1\0` |
| 8 | `u32` | Format version, currently `1` |
| 12 | `u32` | Header size, currently `4096` |
| 16 | `u64` | Exact file size |
| 24 | `u32` | Number of included GeoNames records |
| 28 | `u32` | Maximum GeoNames ID represented by the dense ID map |
| 32 | `u64` | XXHash64 fingerprint of `allCountries.txt` |
| 40 | `u64` | XXHash64 fingerprint of `alternateNamesV2.txt` |
| 48 | `u32` | Number of section descriptors |
| 52 | `u32` | Normalization version, currently `1` |
| 56 | `u32` | Scoring version, currently `1` |
| 60 | `u32` | Reserved, zero |
| 64 | variable | Array of 48-byte section descriptors |

Each section descriptor has the following layout:

| Relative offset | Type | Meaning |
|---:|---|---|
| 0 | `u32` | Section kind ID |
| 4 | `u32` | Flags, currently zero |
| 8 | `u64` | Absolute file offset |
| 16 | `u64` | Section length in bytes |
| 24 | `u64` | Element count |
| 32 | `u32` | Fixed element stride, or zero for a variable-length table |
| 36 | `u32` | Reserved, zero |
| 40 | `u64` | XXHash64 of the section payload |

The record portion contains a dense ID map and fixed-size location records.
Section IDs 3–20 are unused.

| ID | Section | Element format and meaning |
|---:|---|---|
| 1 | `idToRow` | `u32[maximumID + 1]`; GeoNames ID to row, `0xffffffff` if absent |
| 2 | `locations` | One 64-byte record per database row, laid out below |

| Record offset | Type | Meaning |
|---:|---|---|
| 0 | `u32` | GeoNames ID |
| 4, 8 | `f32` | Latitude, longitude |
| 12 | `u32` | Population |
| 16, 20, 24, 28, 32 | `i32` | Country and admin1–admin4 GeoNames IDs; zero means absent |
| 36 | `u32` | Name offset into `canonicalStrings` |
| 40 | `u32` | Start record in `alternateRecords` |
| 44 | `u32` | Start entry in `postcodeOffsets` |
| 48 | `i16` | Elevation |
| 50 | `u16` | Index into `timezoneStrings` |
| 52 | `u16` | Packed ISO-2 country bytes; zero means unknown |
| 54 | `u16` | Alternate record count |
| 56 | `u16` | Postcode count |
| 58 | `u8` | Index into `featureStrings` |
| 59 | 5 bytes | Reserved, zero |

Variable strings are encoded as `[u32 byteLength][UTF-8 bytes]`; offsets point to the length
field. The remaining record-support sections are:

| ID | Section | Layout |
|---:|---|---|
| 21 | `canonicalStrings` | Length-prefixed UTF-8 string pool |
| 22 | `alternateRecords` | 6 bytes: `u16 languageID`, `u32 stringOffset` |
| 23 | `alternateStrings` | Length-prefixed UTF-8 string pool |
| 24 | `postcodeOffsets` | `u32` offsets into `postcodeStrings` |
| 25 | `postcodeStrings` | Length-prefixed UTF-8 string pool |
| 26–28 | `featureStrings`, `timezoneStrings`, `languageStrings` | Sequential length-prefixed UTF-8 tables; descriptor `count` is the number of strings |
| 29–30 | `geoOrdered`, `geoValues` | Reserved for a future spatial index; currently not emitted |

Search index ID `0` contains canonical and language-neutral/common names. A language-specific
index uses `languageID + 1`, where `languageID` is the ordinal in `languageStrings`. Names are
normalized to lowercase, diacritic-insensitive UTF-8 and sorted lexicographically before the
packed radix trie is written.

| ID | Search section | Record layout |
|---:|---|---|
| 31 | `searchRoots` | 24 bytes: `u16 indexID`, `u16 reserved`, `u32 rootNode`, `u32 nameBase`, `u32 nameCount`, `u32 treeStart`, `u32 treeLeafBase` |
| 32 | `searchNodes` | 16 bytes: `u32 firstEdge`, `u16 edgeCount`, `u16 flags`, `u32 subtreeFirstOrdinal`, `u32 subtreeNameCount`; flag bit 0 marks a terminal |
| 33 | `searchEdges` | 12 bytes: `u32 child`, `u32 labelOffset`, `u16 labelLength`, `u8 firstByte`, `u8 reserved` |
| 34 | `searchEdgeLabels` | Concatenated normalized UTF-8 edge labels |
| 35 | `searchNameMetadata` | 12 bytes: `u32 postingStart`, `u32 postingCount`, `u16 characterCount`, `u16 reserved` |
| 36 | `searchPostings` | 16 bytes: `u32 row`, `f32 rank`, packed `u16 country`, `u32 admin1ID`, `u16 sources` |
| 37 | `searchGlobalTrees` | 24-byte rank-bound tree nodes |
| 38, 41 | `searchCountryBuckets`, `searchAdminBuckets` | 28 bytes: `u16 indexID`, `u16 reserved`, `u32 area`, `u32 entryStart`, `u32 entryCount`, `u32 treeStart`, `u32 treeLeafBase`, `u32 reserved` |
| 39, 42 | `searchCountryEntries`, `searchAdminEntries` | 6 bytes: `u32 nameOrdinal`, `u16 maximumRank` |
| 40, 43 | `searchCountryTrees`, `searchAdminTrees` | 24-byte rank-bound tree nodes |

The posting `sources` bitmask uses bits 0–4 for canonical names, localized
alternates, common alternates, airport codes, and postcodes respectively.

Radix edges store path-compressed labels. In an edge's `child` field, bit 31 indicates that
the low 31 bits are a terminal name ordinal instead of a node index. Name ordinals are local
to an index, and their metadata record is `nameBase + ordinal`. Country and
administrative-area sections are sparse views over those same ordinals, so they do not
duplicate names or postings. A country bucket's `area` contains the packed ISO-2 value; an
administrative bucket contains the `u32` bit pattern of its GeoNames ID.

Each rank-bound tree leaf summarizes a block of 64 names. A tree node contains twelve `u16`
upper bounds for the character-length bins `0, 4, 8, 12, 16, 24, 32, 48, 64, 96, 128, 256`.
Ranks are rounded upward after multiplication by 32768; `0xffff` marks an empty bin. The
power-of-two `treeLeafBase` stored in the corresponding root or area bucket locates the first
leaf. These conservative bounds allow top-K traversal to skip subtrees that cannot beat the
current result set.

The database contains an exact-match administrative-alias index for country and first-level
administrative-area qualifiers:

| ID | Administrative-alias section | Record layout |
|---:|---|---|
| 44 | `administrativeAliasRecords` | 16 bytes: `u8 kind`, `u8 reserved`, `u16 languageID`, `u32 nameOffset`, `u32 candidateStart`, `u16 candidateCount`, `u16 reserved` |
| 45 | `administrativeAliasStrings` | Length-prefixed normalized UTF-8 aliases |
| 46 | `administrativeAliasCandidates` | 8 bytes: `u32 admin1ID`, packed `u16 country`, `u16 reserved`; an `admin1ID` of zero denotes the country itself |

Alias records are sorted by kind, language, and normalized UTF-8 bytes, so resolution is a
binary search followed by a short contiguous candidate scan. All three sections are required;
a database missing any of them is rejected.

Service startup performs structural checks on the header, section ranges and strides, and
small lookup tables. Query readers check the ranges they touch. Full verification additionally
checks section hashes, UTF-8 pools, radix references and reachability, posting rows and
ordering, dense ID-map consistency, variable-length ranges, sparse ordinals, rank bounds,
and administrative aliases. The builder fully verifies its output before publishing it;
`verify-database` performs the same full verification for an existing database.

The authoritative definitions are in
[`DatabaseFileFormat.swift`](Sources/App/DatabaseFileFormat.swift),
[`BinaryRecordLayouts.swift`](Sources/App/BinaryRecordLayouts.swift),
[`PackedRadixIndexFormat.swift`](Sources/App/PackedRadixIndexFormat.swift), and
[`AdministrativeAliasIndexFormat.swift`](Sources/App/AdministrativeAliasIndexFormat.swift).

### Build, verify, and start

Run from the repository root. Download and extract `allCountries.txt` and
`alternateNamesV2.txt` into `data/`, then build the executable and database:

```bash
mkdir -p data
curl -fL https://download.geonames.org/export/dump/allCountries.zip -o data/allCountries.zip
curl -fL https://download.geonames.org/export/dump/alternateNamesV2.zip -o data/alternateNamesV2.zip
unzip -o data/allCountries.zip -d data
unzip -o data/alternateNamesV2.zip -d data

swift build -c release --product Run
.build/release/Run build-database --memory-limit-mb 1024
.build/release/Run verify-database
.build/release/Run serve --env production --hostname 0.0.0.0 --port 8080
```

All default paths are relative to the process working directory. The builder and service
both use `data/database-v1.bin`. Startup opens this prebuilt file; a missing or incompatible
file makes startup fail with instructions to build and verify it. Source files being present
does not trigger an automatic build.

The builder streams the TSV inputs, partitions temporary data, and sorts runs sequentially.
`--memory-limit-mb` controls the approximate managed-memory budget, excluding mapped pages;
it is not a hard process-memory limit. The default is 1024 MiB. The builder fully validates
a temporary output before atomically renaming it into place. An existing target is preserved
unless `--force` is supplied:

```bash
.build/release/Run build-database --force --memory-limit-mb 1024
.build/release/Run verify-database --database data/database-v1.bin
```

Format version 1 is the initial supported format. Earlier implementation experiments and
the old protobuf `database.bin` are not supported; rebuild from the source TSV files rather
than renaming an old database. Normalization and scoring versions are also checked at open.
Restart the service after publishing a replacement so it opens the new immutable file.

No full-dataset build-time or memory baseline has been established for this final layout.
Measure using your dataset, hardware, and memory budget; earlier experimental timings are
not representative guarantees for this format.

### Service deployment

Deploy the release executable and its required runtime resources with the verified database.
The supplied [`systemd unit`](build/geocoding-api.service) expects the executable at
`/usr/local/bin/geocoding-api`, working directory `/var/lib/geocoding-api`, and environment
file `/etc/default/geocoding-api.env` defining `API_BIND` and `VAPOR_ENV`. Provision the
`geocoding-api` user and group and make the database readable by that account. Build and
verify before starting the service, using the same working directory:

```bash
cd /var/lib/geocoding-api
sudo -u geocoding-api /usr/local/bin/geocoding-api build-database
sudo -u geocoding-api /usr/local/bin/geocoding-api verify-database
sudo systemctl enable --now geocoding-api.service
sudo systemctl status geocoding-api.service
```

For this workflow, place both source TSVs in `/var/lib/geocoding-api/data/` and allow the
service account to write there during the build. Alternatively, deploy an already built
`data/database-v1.bin`, verify it, and start the service without the source files.

The [`Dockerfile`](Dockerfile) uses `/app` as its working directory; mount the database at
`/app/data/database-v1.bin`. The supplied Compose configuration mounts a named volume at
`/app/data`; populate it with the source files before running
`docker compose run --rm open-meteo build-database`, then run
`docker compose run --rm open-meteo verify-database` before `docker compose up -d`.

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
