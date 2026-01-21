# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] - 2026-01-20

### Fixed

- Fixed tide/current classification for subordinate stations with asymmetric corrections
  - Previously, subordinate stations with different high/low time offsets or level multipliers were incorrectly classified as current stations
  - Now correctly classifies stations based on presence of current-specific indicators (flood/ebb times, direction data)
  - Subordinate tide stations can have different corrections for high vs low tides and are now properly identified as tide stations

## [1.0.0] - 2026-01-20

### Added

- Initial release
- Pure Ruby TCD file reader (no C extensions)
- Support for TCD v2 format
- Read reference and subordinate station records
- Read constituent data (speeds, equilibrium arguments, node factors)
- Constituent inference from M2, S2, K1, O1 (Schureman method)
- Geospatial queries: `nearest_station`, `stations_near`
- Station type detection: `tide?`, `current?`, `simple?`
- Station search by name substring
- `tcd-info` command-line tool
- Comprehensive test suite
