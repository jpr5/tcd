# frozen_string_literal: true

module TCD
    # Data structure for tidal constituent information.
    # Each constituent has a speed and year-indexed equilibrium/node factor arrays.
    Constituent = Struct.new(
        :index,          # Index in the constituent table (0-based)
        :name,           # Constituent name (e.g., "M2", "S2", "K1")
        :speed,          # Angular speed in degrees per hour
        :equilibrium,    # Array of equilibrium arguments by year (degrees)
        :node_factors,   # Array of node factors by year (dimensionless, ~1.0)
        keyword_init: true
    ) do
        # Get equilibrium argument for a specific year
        def equilibrium_for_year(year, start_year)
            idx = year - start_year
            return nil if idx < 0 || idx >= equilibrium.size
            equilibrium[idx]
        end

        # Get node factor for a specific year
        def node_factor_for_year(year, start_year)
            idx = year - start_year
            return nil if idx < 0 || idx >= node_factors.size
            node_factors[idx]
        end

        def to_s
            "#{name}: #{format('%.7f', speed)}°/hr"
        end
    end

    # Reader for constituent data (speeds, equilibrium args, node factors).
    # Data is stored as bit-packed arrays after the lookup tables.
    class ConstituentData
        attr_reader :constituents

        def initialize(bit_buffer, header, lookup_tables)
            @bit = bit_buffer
            @header = header
            @lookup = lookup_tables
            @constituents = []
            load_data
        end

        # Find constituent by name
        def find(name)
            @constituents.find { |c| c.name == name }
        end

        # Find constituent by index
        def [](idx)
            @constituents[idx]
        end

        # Number of constituents
        def size
            @constituents.size
        end

        # Iterate over constituents
        def each(&block)
            @constituents.each(&block)
        end
        include Enumerable

        private

        def load_data
            num_constituents = @header.constituents
            num_years = @header.number_of_years

            # Read speeds for all constituents
            speeds = read_speeds(num_constituents)

            # Read equilibrium arguments: constituents × years matrix
            equilibriums = read_equilibriums(num_constituents, num_years)

            # Read node factors: constituents × years matrix
            node_factors = read_node_factors(num_constituents, num_years)

            # Build Constituent structs
            num_constituents.times do |i|
                @constituents << Constituent.new(
                    index: i,
                    name: @lookup.constituent(i) || "C#{i}",
                    speed: speeds[i],
                    equilibrium: equilibriums[i],
                    node_factors: node_factors[i]
                )
            end
        end

        def read_speeds(count)
            bits = @header.speed_bits
            scale = @header.speed_scale
            offset = @header.speed_offset || 0

            count.times.map do
                raw = @bit.read_uint(bits)
                (raw.to_f + offset) / scale
            end
        end

        def read_equilibriums(num_constituents, num_years)
            bits = @header.equilibrium_bits
            scale = @header.equilibrium_scale
            offset = @header.equilibrium_offset || 0

            num_constituents.times.map do
                num_years.times.map do
                    raw = @bit.read_uint(bits)
                    (raw.to_f + offset) / scale
                end
            end
        end

        def read_node_factors(num_constituents, num_years)
            bits = @header.node_bits
            scale = @header.node_scale
            offset = @header.node_offset || 0

            num_constituents.times.map do
                num_years.times.map do
                    raw = @bit.read_uint(bits)
                    (raw.to_f + offset) / scale
                end
            end
        end
    end
end
