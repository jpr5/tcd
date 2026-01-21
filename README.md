# TCD - Tidal Constituent Database Reader

A pure Ruby gem for reading TCD (Tidal Constituent Database) files used by [XTide](https://flaterco.com/xtide/) for tide predictions.

## Features

- **Pure Ruby** - No C extensions, FFI, or external dependencies
- **Complete TCD v2 support** - Reads all station types and constituent data
- **Lazy loading** - Stations can be iterated without loading all into memory
- **Constituent inference** - Compute missing constituents from major ones (M2, S2, K1, O1)
- **Geospatial queries** - Find nearest stations or stations within a radius

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'tcd'
```

Or install it directly:

```bash
gem install tcd
```

## Usage

### Basic Usage

```ruby
require 'tcd'

TCD.open("harmonics.tcd") do |db|
    puts "Stations: #{db.station_count}"
    puts "Constituents: #{db.constituent_count}"
    puts "Year Range: #{db.year_range}"

    # Search for stations
    db.find_stations("San Francisco").each do |station|
        puts "#{station.name}: #{station.latitude}, #{station.longitude}"
    end
end
```

### Station Types

TCD files contain two types of stations:

- **Reference stations** - Have full harmonic constituent data (amplitudes & epochs)
- **Subordinate stations** - Have time/height offsets relative to a reference station

```ruby
TCD.open("harmonics.tcd") do |db|
    # Get only reference stations
    db.reference_stations.each do |s|
        puts "#{s.name}: #{s.active_constituents} constituents"
    end

    # Get only subordinate stations
    db.subordinate_stations.each do |s|
        puts "#{s.name}: offset from station ##{s.reference_station}"
    end
end
```

### Geospatial Queries

```ruby
TCD.open("harmonics.tcd") do |db|
    # Find nearest station to coordinates
    nearest = db.nearest_station(37.8, -122.4)
    puts "Nearest: #{nearest.name}"

    # Find nearest reference station only
    nearest_ref = db.nearest_station(37.8, -122.4, type: :reference)

    # Find all stations within 1 degree (~111 km at equator)
    nearby = db.stations_near(37.8, -122.4, radius: 1.0)
    puts "Found #{nearby.size} stations within 1 degree"
end
```

### Constituent Data

```ruby
TCD.open("harmonics.tcd") do |db|
    # Access constituent information
    m2 = db.constituent("M2")
    puts "M2 speed: #{m2.speed} degrees/hour"

    # Get equilibrium argument for a specific year
    eq = m2.equilibrium_for_year(2025, db.header.start_year)

    # Get node factor for a specific year
    nf = m2.node_factor_for_year(2025, db.header.start_year)
end
```

### Constituent Inference

For stations with limited observation data, you can infer missing constituents:

```ruby
TCD.open("harmonics.tcd") do |db|
    station = db.station_by_name("Some Station")

    before = station.active_constituents
    if db.infer_constituents(station)
        after = station.active_constituents
        puts "Inferred #{after - before} additional constituents"
    end
end
```

### Station Type Detection

```ruby
TCD.open("harmonics.tcd") do |db|
    db.stations.each do |s|
        if s.tide?
            puts "#{s.name} is a TIDE station"
        elsif s.current?
            puts "#{s.name} is a CURRENT station"
        end
    end
end
```

### Command Line Tool

The gem includes a `tcd-info` command for exploring TCD files:

```bash
# Show database summary
tcd-info harmonics.tcd

# List stations
tcd-info harmonics.tcd --stations 20

# Search for stations
tcd-info harmonics.tcd --search "Boston"

# List constituents
tcd-info harmonics.tcd --constituents
```

## TCD File Format

TCD files are binary databases containing:

- **Header** - ASCII key-value pairs defining encoding parameters
- **Lookup tables** - Countries, timezones, datums, level units, etc.
- **Constituent data** - Speeds, equilibrium arguments, and node factors
- **Station records** - Bit-packed binary records for each station

This gem implements a complete reader for the TCD v2 format as documented in the [libtcd](https://flaterco.com/xtide/libtcd.html) library.

## Obtaining TCD Files

Harmonics data files are available from the [XTide website](https://flaterco.com/xtide/files.html). The "harmonics-dwf" files are free and contain data for thousands of stations worldwide.

## Development

```bash
# Run tests
rake test

# Run tests with a specific TCD file
TCD_TEST_FILE=/path/to/harmonics.tcd rake test

# Run example program
TCD_FILE=/path/to/harmonics.tcd rake example

# Open console
rake console
```

## License

MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [XTide](https://flaterco.com/xtide/) by David Flater
- [libtcd](https://flaterco.com/xtide/libtcd.html) by Jan Depner and David Flater
- Tidal analysis methods from "Manual of Harmonic Analysis and Prediction of Tides" by Paul Schureman
