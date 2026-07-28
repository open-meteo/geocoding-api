# Geocoding API

[![Build](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml/badge.svg)](https://github.com/open-meteo/geocoding-api/actions/workflows/test.yml)

Todo:

- Reconsider using the protobuf library for JSON encoding (faster, but skips empty values; see [swift-protobuf#1171](https://github.com/apple/swift-protobuf/issues/1171)).
- Include the additional [GeoNames postal-code database](https://download.geonames.org/export/zip/). Postal codes present in `alternateNamesV2.txt` are already indexed.
- Add GeoIP support and optionally weight results by distance.
- Add coordinate proximity search. The packed record layout keeps coordinates in columns,
  but a spatial index and API semantics still need to be designed.

ISO-2 country filtering is implemented inside the packed search traversal, before top-K selection.

## Database build

The service uses `data/database-v2.bin`, a versioned, sectioned binary database read with
`mmap`. The record data is stored in structure-of-arrays columns. Search names are stored
once per language/index in packed radix tries, with shared posting lists for matching
locations. Global queries traverse the radix directly; country and administrative-area
queries use sparse ordinal views over the same names. Binned segment-tree rank bounds let
top-K search skip ranges that cannot improve the result. Startup does not decode the full
dataset into Swift objects.

### Memory-mapped file format

`database-v2.bin` is a little-endian, self-describing container. All integers are stored
little-endian, `f32` values use their IEEE 754 bit pattern, and offsets are relative to the
start of the referenced section unless stated otherwise. Each section starts at a 4096-byte
file boundary; alignment padding is zero-filled and is not part of the section length or
hash.

The first 4096 bytes are the header:

| Offset | Type | Meaning |
|---:|---|---|
| 0 | 8 bytes | Magic `GEOCDV2\0` |
| 8 | `u32` | Format version, currently `2` |
| 12 | `u32` | Header size, currently `4096` |
| 16 | `u64` | Exact file size |
| 24 | `u32` | Number of included GeoNames records |
| 28 | `u32` | Maximum GeoNames ID represented by the dense ID map |
| 32 | `u64` | XXHash64 fingerprint of `allCountries.txt` |
| 40 | `u64` | XXHash64 fingerprint of `alternateNamesV2.txt` |
| 48 | `u32` | Number of section descriptors |
| 52 | 12 bytes | Reserved, zero |
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

The record portion uses structure-of-arrays columns. Sections 2–20 have one element per
database row, except for the dense ID map:

| ID | Section | Element format and meaning |
|---:|---|---|
| 1 | `idToRow` | `u32[maximumID + 1]`; GeoNames ID to row, `0xffffffff` if absent |
| 2 | `rowToID` | `u32`; row to GeoNames ID |
| 3–5 | `latitude`, `longitude`, `ranking` | `f32` |
| 6 | `elevation` | `i16` |
| 7 | `feature` | `u8` index into `featureStrings` |
| 8 | `countryISO2` | Two ASCII bytes packed into a `u16`; zero means unknown |
| 9–13 | `countryID`, `admin1ID` … `admin4ID` | `i32` GeoNames IDs; zero means absent |
| 14 | `timezoneIndex` | `u16` index into `timezoneStrings` |
| 15 | `population` | `u32` |
| 16 | `nameOffset` | `u32` byte offset into `canonicalStrings` |
| 17–18 | `alternateStart`, `alternateCount` | `u32` start record and `u16` count |
| 19–20 | `postcodeStart`, `postcodeCount` | `u32` start record and `u16` count |

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
| 36 | `searchPostings` | 14 bytes: `u32 row`, `f32 rank`, packed `u16 country`, `u32 admin1ID` |
| 37 | `searchGlobalTrees` | 24-byte rank-bound tree nodes |
| 38, 41 | `searchCountryBuckets`, `searchAdminBuckets` | 28 bytes: `u16 indexID`, `u16 reserved`, `u32 area`, `u32 entryStart`, `u32 entryCount`, `u32 treeStart`, `u32 treeLeafBase`, `u32 reserved` |
| 39, 42 | `searchCountryEntries`, `searchAdminEntries` | 6 bytes: `u32 nameOrdinal`, `u16 maximumRank` |
| 40, 43 | `searchCountryTrees`, `searchAdminTrees` | 24-byte rank-bound tree nodes |

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

The loader validates the header, section ranges and strides, UTF-8 tables, radix references,
posting ranges, sorted sparse ordinals, and rank-tree ranges before serving requests. The
authoritative definitions are in
[`DatabaseFileFormat.swift`](Sources/App/DatabaseFileFormat.swift) and
[`PackedRadixIndexFormat.swift`](Sources/App/PackedRadixIndexFormat.swift).

After downloading and extracting the two GeoNames inputs, build the database explicitly:

```bash
swift run -c release Run build-database
```

Useful options:

```bash
swift run -c release Run build-database --memory-limit-mb 1024
swift run -c release Run build-database --force
```

The builder streams both TSV files, partitions its temporary data, and atomically renames a
fully validated output file into place. An existing `database-v2.bin` is preserved unless
`--force` is supplied. The old protobuf `database.bin` is not converted or loaded; rebuild
from the source TSV files. The packed-radix layout is format version 2 and is intentionally
not compatible with earlier experimental `database-v2.bin` files; those files must also be
rebuilt.

On the full GeoNames dataset, a measured release build completed in approximately 2 minutes
15 seconds, used about 808 MiB of peak memory, and produced a 1.37 GB database. Build time
depends primarily on CPU and storage performance; roughly 2–5 minutes is a reasonable
expectation on a modern server.

If `database-v2.bin` is absent at service startup but both source files are present, the
service builds it automatically. Running the explicit command is recommended for production
deployments because failures are then visible before restart.


## Installation on ubuntu 20.04
The standalone `geocodingapi` binary can run on any 64-bit linux with recent libc. Currently only basic installation instructions for ubuntu 22.04 are available. Later Docker and others can be provided.

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

GeoNames data can be processed during the first start, but building explicitly as described
above is recommended. The bounded-memory builder no longer requires the full source and
search tree to coexist as Swift objects. Actual build time and memory use depend on the
dataset, CPU, storage, and `--memory-limit-mb`.

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
