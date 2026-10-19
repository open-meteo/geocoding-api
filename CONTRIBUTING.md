# Contributing

Use Swift 6.4, pinned in [`.swift-version`](.swift-version). The package enables the
experimental `Lifetimes` feature and declares Swift tools version 6.4.
Vapor is pinned to `5.0.0-beta.4`; macOS builds require macOS 26.2 or later.

## Build and test

Run from the repository root:

```bash
swift build
swift test
```

Tests use generated fixtures. To run the server with GeoNames data, follow
[Building from source](docs/self-hosting.md#building-from-source).

## Submit a change

Keep each pull request focused on one change. Describe the problem, the resulting
behavior, and the checks you ran. Link the related issue when available.

Read the [database format reference](docs/database-format.md) before changing the
binary layout, normalization, or ranking.

## Report a bug

Follow the [bug-report checklist](README.md#reporting-bugs). Include a small
reproduction that another contributor can run.
