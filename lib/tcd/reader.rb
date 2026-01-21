# frozen_string_literal: true

require_relative "bit_buffer"
require_relative "header"
require_relative "lookup_tables"
require_relative "constituent"
require_relative "station"

module TCD
    # Main reader class for TCD (Tidal Constituent Database) files.
    # Provides access to header info, lookup tables, constituents, and stations.
    class Reader
        attr_reader :path, :header, :lookup_tables, :constituent_data

        def initialize(path)
            @path = path
            @file = File.open(path, "rb")
            @stations_loaded = false
            @stations = []

            load_metadata
        end

        # Close the file handle
        def close
            @file.close unless @file.closed?
        end

        # Database version string
        def version
            @header.version
        end

        # Last modified date string
        def last_modified
            @header.last_modified
        end

        # Number of station records
        def station_count
            @header.number_of_records
        end

        # Number of constituents
        def constituent_count
            @header.constituents
        end

        # Year range covered by equilibrium/node factor data
        def year_range
            start_year = @header.start_year
            end_year = start_year + @header.number_of_years - 1
            start_year..end_year
        end

        # File size in bytes
        def file_size
            @header.end_of_file
        end

        # Access constituents
        def constituents
            @constituent_data
        end

        # Find constituent by name
        def constituent(name)
            @constituent_data.find(name)
        end

        # Load and return all stations (lazy-loaded)
        def stations
            load_stations unless @stations_loaded
            @stations
        end

        # Iterate over stations without loading all into memory
        def each_station(&block)
            return enum_for(:each_station) unless block_given?

            if @stations_loaded
                @stations.each(&block)
            else
                @file.seek(@stations_offset)
                @bit = BitBuffer.new(@file)
                parser = StationParser.new(@bit, @header, @lookup_tables)

                @header.number_of_records.times do |i|
                    station = parser.parse(i)
                    yield station
                end
            end
        end

        # Find stations by name (substring match, case-insensitive)
        def find_stations(query)
            query_down = query.downcase
            stations.select { |s| s.name.downcase.include?(query_down) }
        end

        # Find station by exact name
        def station_by_name(name)
            stations.find { |s| s.name == name }
        end

        # Get reference stations only
        def reference_stations
            stations.select(&:reference?)
        end

        # Get subordinate stations only
        def subordinate_stations
            stations.select(&:subordinate?)
        end

        # Infer missing constituents for a reference station.
        # Requires the station to have non-zero values for M2, S2, K1, and O1.
        # Returns true if inference was performed, false if not enough data.
        def infer_constituents(station)
            Inference.infer_constituents(station, @constituent_data)
        end

        # Find the nearest station to a given latitude/longitude.
        # Uses simple Euclidean distance (suitable for nearby searches).
        # For more accurate global searches, consider using the Haversine formula.
        #
        # @param lat [Float] Latitude in decimal degrees
        # @param lon [Float] Longitude in decimal degrees
        # @param type [Symbol, nil] Optional filter: :reference, :subordinate, or nil for all
        # @return [Station, nil] The nearest station, or nil if no stations found
        def nearest_station(lat, lon, type: nil)
            candidates = case type
                         when :reference then reference_stations
                         when :subordinate then subordinate_stations
                         else stations
                         end

            return nil if candidates.empty?

            candidates.min_by do |s|
                dlat = lat - s.latitude
                dlon = lon - s.longitude
                dlat * dlat + dlon * dlon
            end
        end

        # Find stations within a given radius of a latitude/longitude.
        # Uses simple Euclidean distance in degrees.
        #
        # @param lat [Float] Latitude in decimal degrees
        # @param lon [Float] Longitude in decimal degrees
        # @param radius [Float] Radius in degrees (roughly: 1° ≈ 111 km at equator)
        # @param type [Symbol, nil] Optional filter: :reference, :subordinate, or nil for all
        # @return [Array<Station>] Stations within the radius, sorted by distance
        def stations_near(lat, lon, radius:, type: nil)
            candidates = case type
                         when :reference then reference_stations
                         when :subordinate then subordinate_stations
                         else stations
                         end

            radius_sq = radius * radius

            candidates.select do |s|
                dlat = lat - s.latitude
                dlon = lon - s.longitude
                dlat * dlat + dlon * dlon <= radius_sq
            end.sort_by do |s|
                dlat = lat - s.latitude
                dlon = lon - s.longitude
                dlat * dlat + dlon * dlon
            end
        end

        # Summary statistics
        def stats
            all = stations
            {
                total_stations: all.size,
                reference_stations: all.count(&:reference?),
                subordinate_stations: all.count(&:subordinate?),
                constituents: constituent_count,
                countries: @lookup_tables.countries.size,
                timezones: @lookup_tables.timezones.size,
                datums: @lookup_tables.datums.size,
                year_range: year_range,
                file_size: file_size
            }
        end

        private

        def load_metadata
            # Parse ASCII header
            @header = Header.new(@file)

            # Load lookup tables (handles interleaved string tables and binary data)
            # This also identifies the constituent data offset and station records offset
            @lookup_tables = LookupTables.new(@file, @header)

            # Load constituent data (speeds, equilibrium, node factors) from tracked offset
            @file.seek(@lookup_tables.constituent_data_offset)
            @bit = BitBuffer.new(@file)
            @constituent_data = ConstituentData.new(@bit, @header, @lookup_tables)

            # Station records start after constituent names (tracked by lookup_tables)
            @stations_offset = @lookup_tables.station_records_offset
        end

        def load_stations
            return if @stations_loaded

            @file.seek(@stations_offset)
            @bit = BitBuffer.new(@file)
            parser = StationParser.new(@bit, @header, @lookup_tables)

            @stations = @header.number_of_records.times.map do |i|
                parser.parse(i)
            end

            @stations_loaded = true
        end
    end
end
