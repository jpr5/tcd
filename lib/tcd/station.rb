# frozen_string_literal: true

module TCD
    # Null value constants per TCD spec
    NULLSLACKOFFSET = 0xA00  # 2560 - null indicator for slack offsets
    NULL_DIRECTION = 361     # Null indicator for direction fields

    # Base station record with fields common to all station types
    Station = Struct.new(
        # Header/index fields
        :record_number,      # Implicit record index (0-based)
        :record_size,        # Size of this record in bytes
        :record_type,        # 1 = reference, 2 = subordinate
        :latitude,           # Decimal degrees (-90 to 90)
        :longitude,          # Decimal degrees (-180 to 180)
        :tzfile,             # Timezone file name
        :name,               # Station name
        :reference_station,  # Index of reference station (-1 if self)

        # Metadata fields
        :country,            # Country name
        :source,             # Data source attribution
        :restriction,        # Access restriction text
        :comments,           # Comments field
        :notes,              # Notes field
        :legalese,           # Legal notice text
        :station_id_context, # Station ID context
        :station_id,         # Station ID
        :date_imported,      # Import date (YYYYMMDD or 0)
        :xfields,            # Extended fields (string)
        :direction_units,    # Direction units (degrees true, etc.)
        :min_direction,      # Minimum direction
        :max_direction,      # Maximum direction
        :level_units,        # Level units (feet, meters, etc.)

        # Type 1 (Reference) specific fields
        :datum,              # Datum name (e.g., "MLLW")
        :datum_offset,       # Datum offset (Z0) in level units
        :zone_offset,        # Time zone offset from GMT0 (integer +/-HHMM)
        :expiration_date,    # Expiration date (YYYYMMDD or 0)
        :months_on_station,  # Months of observation data
        :last_date_on_station, # Last date on station (YYYYMMDD)
        :confidence,         # Confidence value (0-15)
        :amplitudes,         # Array of amplitudes per constituent
        :epochs,             # Array of epochs (phases) per constituent

        # Type 2 (Subordinate) specific fields
        :min_time_add,       # Minutes to add to reference low tide time
        :max_time_add,       # Minutes to add to reference high tide time
        :flood_begins,       # Flood begins offset (for currents)
        :ebb_begins,         # Ebb begins offset (for currents)
        :min_level_add,      # Value to add to reference low level
        :max_level_add,      # Value to add to reference high level
        :min_level_multiply, # Multiplier for reference low level
        :max_level_multiply, # Multiplier for reference high level

        keyword_init: true
    ) do
        def reference?
            record_type == 1
        end

        def subordinate?
            record_type == 2
        end

        # Count of non-zero amplitude constituents
        def active_constituents
            return 0 unless amplitudes
            amplitudes.count { |a| a && a > 0 }
        end

        # Check if this is a "simple" subordinate station.
        # A simple subordinate has identical high/low offsets, no direction data,
        # and no flood/ebb slack times. This is common for tide stations
        # (as opposed to current stations which have direction/slack data).
        #
        # @return [Boolean] true if simple, false otherwise (always false for reference stations)
        def simple?
            return false unless subordinate?

            max_time_add == min_time_add &&
                max_level_add == min_level_add &&
                max_level_multiply == min_level_multiply &&
                min_direction.nil? &&
                max_direction.nil? &&
                flood_begins.nil? &&
                ebb_begins.nil?
        end

        # Check if this station has current (not tide) data.
        # Current stations have direction fields and/or flood/ebb slack times.
        #
        # @return [Boolean] true if this is a current station
        def current?
            return false if reference?
            !simple?
        end

        # Check if this station has tide (not current) data.
        # Tide stations are either reference stations or simple subordinates.
        #
        # @return [Boolean] true if this is a tide station
        def tide?
            reference? || simple?
        end

        def to_s
            type_str = reference? ? "Reference" : "Subordinate"
            "#{name} (#{type_str}) @ #{format('%.5f', latitude)}, #{format('%.5f', longitude)}"
        end
    end

    # Parser for station records from bit-packed binary data
    class StationParser
        def initialize(bit_buffer, header, lookup_tables)
            @bit = bit_buffer
            @header = header
            @lookup = lookup_tables
        end

        # Parse a single station record at current position
        def parse(record_number)
            start_pos = @bit.pos

            # ============================================
            # Partial header (common to all record types)
            # Per libtcd unpack_partial_tide_record()
            # ============================================

            # Record size and type
            record_size = @bit.read_uint(@header.record_size_bits)
            record_type = @bit.read_uint(@header.record_type_bits)

            # Geographic coordinates
            latitude = @bit.read_int(@header.latitude_bits).to_f / @header.latitude_scale
            longitude = @bit.read_int(@header.longitude_bits).to_f / @header.longitude_scale

            # Timezone file index (comes BEFORE name in TCD format)
            tzfile_idx = @bit.read_uint(@header.tzfile_bits)
            tzfile = @lookup.timezone(tzfile_idx)

            # Station name (null-terminated string)
            name = @bit.read_cstring

            # Reference station index (-1 for reference stations referring to themselves)
            reference_station = @bit.read_int(@header.station_bits)

            # ============================================
            # Extended fields (V2 format)
            # Per libtcd unpack_tide_record() case 2
            # ============================================

            # Country
            country_idx = @bit.read_uint(@header.country_bits)
            country = @lookup.country(country_idx)

            # Source string
            source = @bit.read_cstring

            # Restriction
            restriction_idx = @bit.read_uint(@header.restriction_bits)
            restriction = @lookup.restriction(restriction_idx)

            # Comments and notes
            comments = @bit.read_cstring
            notes = @bit.read_cstring

            # Legalese
            legalese_idx = @bit.read_uint(@header.legalese_bits)
            legalese = @lookup.legalese_text(legalese_idx)

            # Station ID fields
            station_id_context = @bit.read_cstring
            station_id = @bit.read_cstring

            # Date imported (YYYYMMDD integer)
            date_imported = @bit.read_uint(@header.date_bits)

            # xfields (extended fields string)
            xfields = @bit.read_cstring

            # Direction units
            direction_units_idx = @bit.read_uint(@header.direction_unit_bits)
            direction_units = @lookup.direction_unit(direction_units_idx)

            # Min/max direction
            min_direction = @bit.read_uint(@header.direction_bits)
            max_direction = @bit.read_uint(@header.direction_bits)
            min_direction = nil if min_direction == NULL_DIRECTION
            max_direction = nil if max_direction == NULL_DIRECTION

            # Level units
            level_units_idx = @bit.read_uint(@header.level_unit_bits)
            level_units = @lookup.level_unit(level_units_idx)

            # Build base station
            station = Station.new(
                record_number: record_number,
                record_size: record_size,
                record_type: record_type,
                latitude: latitude,
                longitude: longitude,
                tzfile: tzfile,
                name: name,
                reference_station: reference_station,
                country: country,
                source: source,
                restriction: restriction,
                comments: comments,
                notes: notes,
                legalese: legalese,
                station_id_context: station_id_context,
                station_id: station_id,
                date_imported: date_imported,
                xfields: xfields,
                direction_units: direction_units,
                min_direction: min_direction,
                max_direction: max_direction,
                level_units: level_units
            )

            # Parse type-specific fields
            if record_type == 1
                parse_reference_fields(station)
            else
                parse_subordinate_fields(station)
            end

            # Ensure we're at the right position for the next record
            # Record size is total bytes from start of record
            expected_end = start_pos + record_size
            @bit.seek(expected_end)

            station
        end

        private

        def parse_reference_fields(station)
            # V2 Reference station fields (in order per libtcd)

            # Datum offset (Z0) - signed
            station.datum_offset = @bit.read_int(@header.datum_offset_bits).to_f / @header.datum_offset_scale

            # Datum
            datum_idx = @bit.read_uint(@header.datum_bits)
            station.datum = @lookup.datum(datum_idx)

            # Zone offset (integer +/-HHMM) - signed
            station.zone_offset = @bit.read_int(@header.time_bits)

            # Expiration date (YYYYMMDD)
            station.expiration_date = @bit.read_uint(@header.date_bits)

            # Months on station
            station.months_on_station = @bit.read_uint(@header.months_on_station_bits)

            # Last date on station
            station.last_date_on_station = @bit.read_uint(@header.date_bits)

            # Confidence value
            station.confidence = @bit.read_uint(@header.confidence_value_bits)

            # Initialize amplitude/epoch arrays
            num_constituents = @header.constituents
            station.amplitudes = Array.new(num_constituents, 0.0)
            station.epochs = Array.new(num_constituents, 0.0)

            # Read the count of non-zero constituents
            count = @bit.read_uint(@header.constituent_bits)

            # Read each constituent's index, amplitude, and epoch
            count.times do
                idx = @bit.read_uint(@header.constituent_bits)
                amplitude = @bit.read_uint(@header.amplitude_bits).to_f / @header.amplitude_scale
                epoch = @bit.read_uint(@header.epoch_bits).to_f / @header.epoch_scale

                if idx < num_constituents
                    station.amplitudes[idx] = amplitude
                    station.epochs[idx] = epoch
                end
            end
        end

        def parse_subordinate_fields(station)
            # V2 Subordinate station fields (in order per libtcd)
            # Note: V2 has a different order than the documentation suggests!

            # Time offsets (signed)
            station.min_time_add = decode_time_offset(@bit.read_int(@header.time_bits))

            # Level add (signed)
            station.min_level_add = @bit.read_int(@header.level_add_bits).to_f / @header.level_add_scale

            # Level multiply (UNSIGNED in V2!)
            min_mult_raw = @bit.read_uint(@header.level_multiply_bits)
            station.min_level_multiply = min_mult_raw == 0 ? 1.0 : min_mult_raw.to_f / @header.level_multiply_scale

            station.max_time_add = decode_time_offset(@bit.read_int(@header.time_bits))

            station.max_level_add = @bit.read_int(@header.level_add_bits).to_f / @header.level_add_scale

            max_mult_raw = @bit.read_uint(@header.level_multiply_bits)
            station.max_level_multiply = max_mult_raw == 0 ? 1.0 : max_mult_raw.to_f / @header.level_multiply_scale

            # Flood/ebb begins (signed)
            flood_raw = @bit.read_int(@header.time_bits)
            ebb_raw = @bit.read_int(@header.time_bits)

            # Check for null slack offsets
            station.flood_begins = (flood_raw == NULLSLACKOFFSET) ? nil : decode_time_offset(flood_raw)
            station.ebb_begins = (ebb_raw == NULLSLACKOFFSET) ? nil : decode_time_offset(ebb_raw)
        end

        # Decode time offset from hours*100+minutes format to total minutes
        def decode_time_offset(raw)
            return 0 if raw == 0
            sign = raw < 0 ? -1 : 1
            raw = raw.abs
            hours = raw / 100
            minutes = raw % 100
            sign * (hours * 60 + minutes)
        end
    end
end
