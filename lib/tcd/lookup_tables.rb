# frozen_string_literal: true

module TCD
    # Reader for TCD lookup tables (fixed-size string arrays).
    #
    # TCD v2 stores string tables in this order after the 4-byte checksum:
    # 1. Level units (level_unit_types × level_unit_size) - exact count
    # 2. Direction units (dir_unit_types × dir_unit_size) - exact count
    # 3. Restrictions (max_restriction_types × restriction_size) - reads until "__END__"
    # 4. [v1 only: Pedigrees - skipped in v2]
    # 5. Timezones (max_tzfiles × tzfile_size) - reads until "__END__"
    # 6. Countries (max_countries × country_size) - reads until "__END__"
    # 7. Datums (max_datum_types × datum_size) - reads until "__END__"
    # 8. [v2 only: Legalese (max_legaleses × legalese_size) - reads until "__END__"]
    # 9. Constituent names (constituents × constituent_size) - exact count
    # 10. Constituent speeds (bit-packed)
    # 11. Equilibrium arguments (bit-packed)
    # 12. Node factors (bit-packed)
    # 13. Station records (bit-packed)
    #
    class LookupTables
        attr_reader :level_units, :direction_units, :restrictions
        attr_reader :legalese, :datums, :constituents
        attr_reader :timezones, :countries

        # Positions tracked for the reader
        attr_reader :constituent_data_offset  # Where bit-packed constituent data starts
        attr_reader :station_records_offset   # Where station records start

        def initialize(io, header)
            @io = io
            @header = header
            load_tables
        end

        # Lookup by index with bounds checking
        def level_unit(idx);     safe_lookup(@level_units, idx); end
        def direction_unit(idx); safe_lookup(@direction_units, idx); end
        def restriction(idx);    safe_lookup(@restrictions, idx); end
        def legalese_text(idx);  safe_lookup(@legalese, idx); end
        def datum(idx);          safe_lookup(@datums, idx); end
        def constituent(idx);    safe_lookup(@constituents, idx); end
        def country(idx);        safe_lookup(@countries, idx); end

        # Timezone strings in TCD files have a leading colon (e.g., ":America/New_York")
        # Strip it to return standard IANA timezone names
        def timezone(idx)
            tz = safe_lookup(@timezones, idx)
            tz&.sub(/^:/, '')
        end

        private

        def load_tables
            # Seek to start of binary section (right after ASCII header)
            @io.seek(@header.header_size)

            # Skip 4-byte CRC/checksum at start of binary section
            @io.read(4)

            # Tables are stored in fixed order per libtcd.
            # Some tables use exact count, others allocate max space based on bits.

            # 1. Level units - exact count
            @level_units = read_table_exact(@header.level_unit_types, @header.level_unit_size)

            # 2. Direction units - exact count
            @direction_units = read_table_exact(@header.direction_unit_types, @header.direction_unit_size)

            # 3. Restrictions - max entries based on bits, reads until "__END__"
            max_restrictions = 2**@header.restriction_bits
            @restrictions = read_table_with_end(max_restrictions, @header.restriction_size)

            # 4. Pedigrees - skipped in v2 (major_rev >= 2)
            #    In v1, space was allocated: pedigree_size × 2^pedigree_bits
            #    But in v2, we skip this entirely
            if @header.major_rev && @header.major_rev < 2 && @header[:pedigree_bits] && @header[:pedigree_size]
                pedigree_max = 2**@header[:pedigree_bits]
                @io.seek(@io.pos + pedigree_max * @header[:pedigree_size])
            end

            # 5. Timezones - max entries based on bits, reads until "__END__"
            max_tzfiles = 2**@header.tzfile_bits
            @timezones = read_table_with_end(max_tzfiles, @header.tzfile_size)

            # 6. Countries - max entries based on bits, reads until "__END__"
            max_countries = 2**@header.country_bits
            @countries = read_table_with_end(max_countries, @header.country_size)

            # 7. Datums - max entries based on bits, reads until "__END__"
            max_datums = 2**@header.datum_bits
            @datums = read_table_with_end(max_datums, @header.datum_size)

            # 8. Legalese - v2 only (major_rev >= 2), max based on bits
            if @header.major_rev && @header.major_rev >= 2 && @header.legalese_bits && @header.legalese_size
                max_legaleses = 2**@header.legalese_bits
                @legalese = read_table_with_end(max_legaleses, @header.legalese_size)
            else
                @legalese = ["NULL"]
            end

            # 9. Constituent names - exact count
            @constituents = read_table_exact(@header.constituents, @header.constituent_size)

            # After constituent names, constituent binary data begins (speeds, equilibriums, node factors)
            @constituent_data_offset = @io.pos

            # Calculate size of constituent binary data in bytes
            constituent_bytes = calculate_constituent_data_bytes
            @station_records_offset = @constituent_data_offset + constituent_bytes
        end

        # Read a table with exact count (no __END__ marker)
        def read_table_exact(count, entry_size)
            entries = []
            count.times do
                bytes = @io.read(entry_size)
                break if bytes.nil? || bytes.empty?
                entries << decode_string(bytes)
            end
            entries
        end

        # Read a table that uses __END__ as terminator but allocates max space
        def read_table_with_end(max_entries, entry_size)
            start_pos = @io.pos
            entries = []

            max_entries.times do
                bytes = @io.read(entry_size)
                break if bytes.nil? || bytes.empty?

                str = decode_string(bytes)
                break if str == "__END__"

                entries << str
            end

            # Seek past the full allocated space regardless of where __END__ was found
            @io.seek(start_pos + max_entries * entry_size)
            entries
        end

        def decode_string(bytes)
            # Handle encoding: TCD uses ISO-8859-1
            bytes.force_encoding("ISO-8859-1")

            # Find null terminator and truncate
            null_pos = bytes.index("\x00")
            str = null_pos ? bytes[0, null_pos] : bytes

            # Convert to UTF-8 for Ruby compatibility
            str.encode("UTF-8", invalid: :replace, undef: :replace)
        end

        def calculate_constituent_data_bytes
            num_c = @header.constituents
            num_y = @header.number_of_years

            # In v2, we use bits2bytes which is (bits + 7) / 8
            # In v1, there was a "wasted byte bug": (bits / 8) + 1

            is_v1 = @header.major_rev && @header.major_rev < 2

            # Speeds: one per constituent
            speed_bits = num_c * @header.speed_bits
            speed_bytes = is_v1 ? (speed_bits / 8) + 1 : (speed_bits + 7) / 8

            # Equilibrium arguments: constituents × years matrix
            eq_bits = num_c * num_y * @header.equilibrium_bits
            eq_bytes = is_v1 ? (eq_bits / 8) + 1 : (eq_bits + 7) / 8

            # Node factors: constituents × years matrix
            node_bits = num_c * num_y * @header.node_bits
            node_bytes = is_v1 ? (node_bits / 8) + 1 : (node_bits + 7) / 8

            speed_bytes + eq_bytes + node_bytes
        end

        def safe_lookup(table, idx)
            return nil if idx.nil? || idx < 0 || idx >= table.size
            table[idx]
        end
    end
end
