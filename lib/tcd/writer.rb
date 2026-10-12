# frozen_string_literal: true

require "zlib"

module TCD
    # Writes a TCD (Tidal Constituent Database) file in the layout libtcd 2.2.7 writes
    # and reads (tide_db.c write_tide_db_header and pack_tide_record):
    #
    #   1. ASCII header ([KEY] = VALUE lines), padded with NULs to [HEADER SIZE]
    #   2. CRC-32 of the padded header, 4 bytes big-endian
    #   3. String tables: level units, direction units, restrictions, time zones,
    #      countries, datums, legalese (the last five padded to 2^bits entries and
    #      ended by "__END__"), constituent names
    #   4. Speeds, equilibrium arguments, node factors (bit-packed, each table
    #      starting on a byte boundary)
    #   5. Station records (bit-packed, each a whole number of bytes)
    #
    # Values use the same units as the reader: degrees, degrees per hour, time
    # offsets in minutes, nil for "no direction" and "no slack time", station time
    # zones with or without the leading ':' (a new table entry always gets it).
    # Strings are stored as ISO-8859-1. A value that does not fit its field raises
    # ArgumentError; nothing is truncated.
    #
    # Checks follow libtcd's check_tide_record, so libtcd and XTide read the file
    # as written:
    # - zone_offset is a signed HHMM integer (-500 is UTC-5, 530 is UTC+5:30),
    #   not minutes; its minutes part must be under 60.
    # - Epochs must be 0..360 degrees; dates must be 0 or YYYYMMDD.
    # - Integer fields take an Integer or a whole Float (10.0), never a fraction.
    # - Strings may not contain NUL; table entries may not be "__END__"; header
    #   text (version, last_modified) may not hold control characters or brackets.
    # - Level units, direction units, restrictions and legalese hold at most 256
    #   entries; time zones, countries and datums at most 32,768. The direction
    #   units table must hold "degrees true" after its first entry.
    # - Every bit width is at most 31. When the speeds span too much for libtcd's
    #   speed scale of 10^7, the writer uses the largest power of ten that fits.
    # - A subordinate's reference_station must index a reference record.
    #
    #   writer = TCD::Writer.new(constituents: [...], start_year: 2020, number_of_years: 3)
    #   writer.add_station(station)   # a TCD::Station or a Hash with the same keys
    #   writer.write("out.tcd")
    #
    #   TCD::Writer.from_reader(reader).write("copy.tcd")
    class Writer
        LIBTCD_VERSION = "PFM Software - libtcd v2.2.7 - 2015-08-09"
        MAJOR_REV = 2
        MINOR_REV = 2

        ONELINER_LENGTH = 90       # bytes, including the NUL
        MONOLOGUE_LENGTH = 10_000  # bytes, including the NUL
        MAX_CONSTITUENTS = 255
        AMPLITUDE_EPSILON = 0.00005
        NULL_SLACK_OFFSET = 0xA00
        NULL_DIRECTION = 361
        END_MARKER = "__END__"
        INT32_MIN = -(2**31)
        INT32_MAX = 2**31 - 1
        MAX_BITS = 31 # libtcd packs every field from a signed 32-bit int

        # Most table entries libtcd can index (tcd.h TIDE_RECORD): level units,
        # direction units, restrictions and legalese are NV_U_BYTE; time zones,
        # countries and datums are NV_INT16, and libtcd asserts tzfile >= 0.
        TABLE_LIMITS = {
            level_unit: 256, direction_unit: 256, restriction: 256, legalese: 256,
            tzfile: 32_768, country: 32_768, datum: 32_768
        }.freeze

        # libtcd tide_db_default.h
        DEFAULTS = {
            header_size: 4096,
            speed_scale: 10_000_000, equilibrium_scale: 100, node_scale: 10_000,
            amplitude_bits: 19, amplitude_scale: 10_000,
            epoch_bits: 16, epoch_scale: 100,
            record_type_bits: 4,
            latitude_bits: 25, latitude_scale: 100_000,
            longitude_bits: 26, longitude_scale: 100_000,
            record_size_bits: 16,
            station_bits: 18,
            datum_offset_bits: 28, datum_offset_scale: 10_000,
            date_bits: 27,
            months_on_station_bits: 10,
            confidence_value_bits: 4,
            time_bits: 13,
            level_add_bits: 17, level_add_scale: 1000,
            level_multiply_bits: 16, level_multiply_scale: 1000,
            direction_bits: 9,
            constituent_size: 10,
            level_unit_size: 15, direction_unit_size: 15,
            restriction_bits: 4, restriction_size: 30,
            tzfile_bits: 10, tzfile_size: 30,
            country_bits: 9, country_size: 50,
            datum_bits: 7, datum_size: 70,
            legalese_bits: 4, legalese_size: 70
        }.freeze

        # Header parameters a caller (or from_reader) may set. Counts and the
        # bit widths that follow from counts are always derived from the data.
        PARAMETER_KEYS = (DEFAULTS.keys + %i[
            speed_bits speed_offset equilibrium_bits equilibrium_offset node_bits node_offset
            constituent_bits level_unit_bits direction_unit_bits
        ]).freeze

        DEFAULT_LEVEL_UNITS = ["Unknown", "feet", "meters", "knots", "knots^2"].freeze
        DEFAULT_DIRECTION_UNITS = ["Unknown", "degrees true", "degrees"].freeze
        DEFAULT_RESTRICTIONS = ["Public Domain", "DoD/DoD Contractors Only"].freeze
        DEFAULT_LEGALESES = ["NULL"].freeze

        attr_reader :stations, :constituents, :params

        # Builds a writer holding everything a Reader read: header parameters,
        # tables, constituents and stations, in the same order.
        def self.from_reader(reader)
            lt = reader.lookup_tables
            h = reader.header
            writer = new(
                constituents: reader.constituents.to_a,
                start_year: h.start_year,
                number_of_years: h.number_of_years,
                version: h.version,
                last_modified: h.last_modified,
                params: h.params.select { |k, _| PARAMETER_KEYS.include?(k) },
                level_units: lt.level_units,
                direction_units: lt.direction_units,
                restrictions: lt.restrictions,
                timezones: lt.timezones,
                countries: lt.countries,
                datums: lt.datums,
                legaleses: lt.legalese
            )
            offset = lt.station_records_offset
            File.open(reader.path, "rb") do |io|
                reader.stations.each do |station|
                    writer.add_station(writer.send(:restore_null_multipliers, station, io, offset))
                    offset += station.record_size
                end
            end
            writer
        end

        # constituents: objects or Hashes with name, speed, equilibrium (one per
        #   year) and node_factors (one per year), e.g. TCD::Constituent.
        # params: header parameters (bit widths, scales, offsets, sizes); missing
        #   ones come from the libtcd defaults or, for speeds, equilibrium
        #   arguments and node factors, from the data range as libtcd computes them.
        # level_units ... legaleses: the string tables. Stations may also name
        #   strings that are not in them; those are appended.
        def initialize(constituents:, start_year:, number_of_years: nil, version: nil, last_modified: nil,
                       params: {}, level_units: DEFAULT_LEVEL_UNITS, direction_units: DEFAULT_DIRECTION_UNITS,
                       restrictions: DEFAULT_RESTRICTIONS, timezones: [], countries: ["Unknown"],
                       datums: ["Unknown"], legaleses: DEFAULT_LEGALESES)
            @constituents = constituents.map { |c| normalize_constituent(c) }
            raise ArgumentError, "at least one constituent is required" if @constituents.empty?
            if @constituents.size > MAX_CONSTITUENTS
                raise ArgumentError, "#{@constituents.size} constituents; libtcd allows at most #{MAX_CONSTITUENTS}"
            end

            @start_year = int_value(start_year, "start_year")
            unless @start_year.between?(INT32_MIN, INT32_MAX)
                raise ArgumentError, "start_year #{@start_year} is outside libtcd's 32-bit range"
            end
            @number_of_years = int_value(number_of_years || @constituents.first[:equilibrium].size, "number_of_years")
            unless @number_of_years.between?(1, INT32_MAX)
                raise ArgumentError, "number_of_years must be at least 1, got #{@number_of_years}"
            end
            @constituents.each do |c|
                [:equilibrium, :node_factors].each do |key|
                    next if c[key].size == @number_of_years
                    raise ArgumentError, "constituent #{c[:name]}: #{c[key].size} #{key} values for #{@number_of_years} years"
                end
            end
            @version = header_text(version || LIBTCD_VERSION, "version")
            @last_modified = last_modified && header_text(last_modified, "last_modified")
            @given_params = params.transform_keys(&:to_sym)
            unknown = @given_params.keys - PARAMETER_KEYS
            raise ArgumentError, "unknown header parameters: #{unknown.join(', ')}" unless unknown.empty?
            @multiply_scale = int_value(@given_params.fetch(:level_multiply_scale, DEFAULTS[:level_multiply_scale]),
                                        "header parameter level_multiply_scale")
            @tables = {
                level_unit: level_units.dup,
                direction_unit: direction_units.dup,
                restriction: restrictions.dup,
                tzfile: timezones.dup,
                country: countries.dup,
                datum: datums.dup,
                legalese: legaleses.dup
            }
            @stations = []
        end

        # Adds a station record (TCD::Station or a Hash with the Station keys).
        # Subordinate stations name their reference by record index
        # (reference_station), so add them in the order they will be numbered.
        def add_station(station)
            @stations << station
            self
        end

        # Writes the file and returns its size in bytes.
        def write(path)
            bytes = to_bytes
            File.binwrite(path, bytes)
            bytes.bytesize
        end

        # The whole file as a binary String.
        def to_bytes
            records = @stations.map { |s| index_strings(s) }
            @params = compute_params
            body = String.new(encoding: Encoding::BINARY)
            body << tables_bytes
            body << constituent_bytes
            records.each_with_index do |r, i|
                if r[:record_type] == 2
                    ref = r[:reference_station]
                    unless ref.between?(0, records.size - 1)
                        raise ArgumentError, "#{r[:name]}: reference_station #{ref} is not a record index (0..#{records.size - 1})"
                    end
                    # XTide asserts when a subordinate's reference is not a reference record
                    unless records[ref][:record_type] == 1
                        raise ArgumentError, "#{r[:name]}: reference_station #{ref} is not a reference (type 1) record"
                    end
                end
                body << pack_station(r, i).first
            end

            end_of_file = @params[:header_size] + 4 + body.bytesize
            raise ArgumentError, "file would be #{end_of_file} bytes, over libtcd's 32-bit limit" if end_of_file > INT32_MAX

            header = header_bytes(end_of_file)
            header + [Zlib.crc32(header)].pack("N") + body
        end

        private

        # ---------------------------------------------------------------
        # Header

        def header_bytes(end_of_file)
            p = @params
            n = @tables
            lines = [
                ["VERSION", @version],
                ["MAJOR REV", MAJOR_REV],
                ["MINOR REV", MINOR_REV],
                ["LAST MODIFIED", @last_modified || Time.now.strftime("%Y-%m-%d %H:%M %Z")],
                ["HEADER SIZE", p[:header_size]],
                ["NUMBER OF RECORDS", @stations.size],
                ["START YEAR", @start_year],
                ["NUMBER OF YEARS", @number_of_years],
                ["SPEED BITS", p[:speed_bits]],
                ["SPEED SCALE", p[:speed_scale]],
                ["SPEED OFFSET", p[:speed_offset]],
                ["EQUILIBRIUM BITS", p[:equilibrium_bits]],
                ["EQUILIBRIUM SCALE", p[:equilibrium_scale]],
                ["EQUILIBRIUM OFFSET", p[:equilibrium_offset]],
                ["NODE BITS", p[:node_bits]],
                ["NODE SCALE", p[:node_scale]],
                ["NODE OFFSET", p[:node_offset]],
                ["AMPLITUDE BITS", p[:amplitude_bits]],
                ["AMPLITUDE SCALE", p[:amplitude_scale]],
                ["EPOCH BITS", p[:epoch_bits]],
                ["EPOCH SCALE", p[:epoch_scale]],
                ["RECORD TYPE BITS", p[:record_type_bits]],
                ["LATITUDE BITS", p[:latitude_bits]],
                ["LATITUDE SCALE", p[:latitude_scale]],
                ["LONGITUDE BITS", p[:longitude_bits]],
                ["LONGITUDE SCALE", p[:longitude_scale]],
                ["RECORD SIZE BITS", p[:record_size_bits]],
                ["STATION BITS", p[:station_bits]],
                ["DATUM OFFSET BITS", p[:datum_offset_bits]],
                ["DATUM OFFSET SCALE", p[:datum_offset_scale]],
                ["DATE BITS", p[:date_bits]],
                ["MONTHS ON STATION BITS", p[:months_on_station_bits]],
                ["CONFIDENCE VALUE BITS", p[:confidence_value_bits]],
                ["TIME BITS", p[:time_bits]],
                ["LEVEL ADD BITS", p[:level_add_bits]],
                ["LEVEL ADD SCALE", p[:level_add_scale]],
                ["LEVEL MULTIPLY BITS", p[:level_multiply_bits]],
                ["LEVEL MULTIPLY SCALE", p[:level_multiply_scale]],
                ["DIRECTION BITS", p[:direction_bits]],
                ["LEVEL UNIT BITS", p[:level_unit_bits]],
                ["LEVEL UNIT TYPES", n[:level_unit].size],
                ["LEVEL UNIT SIZE", p[:level_unit_size]],
                ["DIRECTION UNIT BITS", p[:direction_unit_bits]],
                ["DIRECTION UNIT TYPES", n[:direction_unit].size],
                ["DIRECTION UNIT SIZE", p[:direction_unit_size]],
                ["RESTRICTION BITS", p[:restriction_bits]],
                ["RESTRICTION TYPES", n[:restriction].size],
                ["RESTRICTION SIZE", p[:restriction_size]],
                ["DATUM BITS", p[:datum_bits]],
                ["DATUM TYPES", n[:datum].size],
                ["DATUM SIZE", p[:datum_size]],
                ["LEGALESE BITS", p[:legalese_bits]],
                ["LEGALESE TYPES", n[:legalese].size],
                ["LEGALESE SIZE", p[:legalese_size]],
                ["CONSTITUENT BITS", p[:constituent_bits]],
                ["CONSTITUENTS", @constituents.size],
                ["CONSTITUENT SIZE", p[:constituent_size]],
                ["TZFILE BITS", p[:tzfile_bits]],
                ["TZFILES", n[:tzfile].size],
                ["TZFILE SIZE", p[:tzfile_size]],
                ["COUNTRY BITS", p[:country_bits]],
                ["COUNTRIES", n[:country].size],
                ["COUNTRY SIZE", p[:country_size]],
                ["END OF FILE", end_of_file]
            ]
            text = String.new(encoding: Encoding::BINARY)
            lines.each do |key, value|
                line = latin1("[#{key}] = #{value}\n", key)
                # libtcd reads header lines into a ONELINER_LENGTH buffer
                if line.bytesize > ONELINER_LENGTH - 2
                    raise ArgumentError, "header line too long for libtcd: #{line.strip}"
                end
                text << line
            end
            text << "[END OF ASCII HEADER DATA]\n"
            if text.bytesize > @params[:header_size]
                raise ArgumentError, "ASCII header is #{text.bytesize} bytes, over header_size #{@params[:header_size]}"
            end
            text + ("\0" * (@params[:header_size] - text.bytesize))
        end

        # Header parameters: given ones, else derived from the data as libtcd's
        # create_tide_db does, else the libtcd defaults.
        def compute_params
            given = @given_params.to_h { |k, v| [k, int_value(v, "header parameter #{k}")] }
            given.each do |k, v|
                ok = case k.to_s
                     when /_bits\z/ then v.between?(1, MAX_BITS)
                     when /_offset\z/ then v.between?(0, INT32_MAX)
                     else v.between?(1, INT32_MAX) # scales, sizes, header_size
                     end
                next if ok

                raise ArgumentError, "header parameter #{k} = #{v} is out of range " \
                                     "(bit widths 1..#{MAX_BITS}, scales and sizes >= 1, offsets >= 0)"
            end
            p = DEFAULTS.merge(given)

            speeds = @constituents.map { |c| c[:speed] }
            if speeds.any?(&:negative?)
                raise ArgumentError, "negative constituent speed"
            end
            if @constituents.any? { |c| c[:equilibrium].any?(&:negative?) }
                raise ArgumentError, "equilibrium arguments must be >= 0 (libtcd reads a negative offset as a " \
                                     "corrupt pre-1.11 file)"
            end
            if @constituents.any? { |c| c[:node_factors].any? { |f| f <= 0 } }
                raise ArgumentError, "node factors must be positive"
            end
            # libtcd's create_tide_db scale is 10^7, asserting the width stays under
            # 32 bits; when the speed range is too wide for that, use the largest
            # power of ten that fits.
            unless given.key?(:speed_scale)
                p[:speed_scale] /= 10 while p[:speed_scale] > 1 &&
                                            range_bits(speeds, p[:speed_scale], given[:speed_offset]) > MAX_BITS
            end
            derive_range(p, :speed, speeds)
            derive_range(p, :equilibrium, @constituents.flat_map { |c| c[:equilibrium] })
            derive_range(p, :node, @constituents.flat_map { |c| c[:node_factors] })

            check_table_limits
            # A reference record stores the count of its constituents in
            # constituent_bits, so the count itself must fit.
            p[:constituent_bits] = [p[:constituent_bits] || 0, calculate_bits(@constituents.size)].max
            # libtcd gives a one-entry unit table a 0-bit field, which the gem's
            # reader cannot read; at least 1 bit is still valid for libtcd.
            p[:level_unit_bits] = [p[:level_unit_bits] || 0, calculate_bits(@tables[:level_unit].size - 1), 1].max
            p[:direction_unit_bits] = [p[:direction_unit_bits] || 0,
                                       calculate_bits(@tables[:direction_unit].size - 1), 1].max
            # The padded tables need room for "__END__" after the last entry.
            %i[restriction tzfile country datum legalese].each do |t|
                key = :"#{t}_bits"
                p[key] = [p[key], calculate_bits(@tables[t].size), 1].max
            end
            # reference_station is signed and holds record indexes
            p[:station_bits] = [p[:station_bits], calculate_bits(@stations.size) + 1].max
            p.each do |k, v|
                next unless k.to_s.end_with?("_bits") && v > MAX_BITS

                raise ArgumentError, "#{k} would be #{v}; libtcd allows at most #{MAX_BITS}"
            end
            p
        end

        # Bits needed for values at scale (offset from the minimum unless given).
        def range_bits(values, scale, offset = nil)
            offset ||= nint(values.min * scale)
            calculate_bits([nint(values.max * scale) - offset, 0].max)
        end

        # Offset and width for one bit-packed constituent table, from the data
        # range unless given.
        def derive_range(p, name, values)
            scale = p[:"#{name}_scale"]
            p[:"#{name}_offset"] ||= nint(values.min * scale)
            if p[:"#{name}_offset"].negative? || p[:"#{name}_offset"] > INT32_MAX
                raise ArgumentError, "#{name} offset #{p[:"#{name}_offset"]} is outside 0..#{INT32_MAX}"
            end
            bits = p[:"#{name}_bits"] ||= [range_bits(values, scale, p[:"#{name}_offset"]), 1].max
            return if bits <= MAX_BITS

            raise ArgumentError, "#{name} values #{values.min}..#{values.max} need #{bits} bits at scale #{scale}; " \
                                 "libtcd allows at most #{MAX_BITS}"
        end

        # libtcd's per-table limits, and the "degrees true" entry it looks up
        # (unpack_tide_record asserts find_dir_units("degrees true") > 0).
        def check_table_limits
            TABLE_LIMITS.each do |t, max|
                next if @tables[t].size <= max

                raise ArgumentError, "#{@tables[t].size} #{t} table entries; libtcd allows at most #{max}"
            end
            idx = @tables[:direction_unit].index("degrees true")
            return if idx&.positive?

            raise ArgumentError, "the direction units table must contain \"degrees true\" after its first entry " \
                                 "(libtcd asserts on it); got #{@tables[:direction_unit].inspect}"
        end

        # ---------------------------------------------------------------
        # Tables

        def tables_bytes
            p = @params
            out = String.new(encoding: Encoding::BINARY)
            out << exact_table(@tables[:level_unit], p[:level_unit_size], "level unit")
            out << exact_table(@tables[:direction_unit], p[:direction_unit_size], "direction unit")
            out << end_table(@tables[:restriction], p[:restriction_bits], p[:restriction_size], "restriction")
            out << end_table(@tables[:tzfile], p[:tzfile_bits], p[:tzfile_size], "time zone")
            out << end_table(@tables[:country], p[:country_bits], p[:country_size], "country")
            out << end_table(@tables[:datum], p[:datum_bits], p[:datum_size], "datum")
            out << end_table(@tables[:legalese], p[:legalese_bits], p[:legalese_size], "legalese")
            out << exact_table(@constituents.map { |c| c[:name] }, p[:constituent_size], "constituent name")
            out
        end

        def exact_table(entries, size, what)
            entries.map { |e| table_entry(e, size, what) }.join
        end

        def end_table(entries, bits, size, what)
            max = 1 << bits
            if entries.size >= max
                raise ArgumentError, "#{entries.size} #{what} entries do not fit #{bits} bits with the end marker"
            end
            out = entries.map { |e| table_entry(e, size, what) }.join
            out << table_entry(END_MARKER, size, :end_marker)
            out << ("\0" * ((max - entries.size - 1) * size))
        end

        def table_entry(value, size, what)
            if value == END_MARKER && what != :end_marker
                raise ArgumentError, "#{what} entry #{END_MARKER.inspect} would end the table early in libtcd and the reader"
            end
            bytes = latin1(value, what)
            if bytes.bytesize + 1 > size
                raise ArgumentError, "#{what} #{value.inspect} is #{bytes.bytesize} bytes; the table holds #{size - 1}"
            end
            bytes + ("\0" * (size - bytes.bytesize))
        end

        # ---------------------------------------------------------------
        # Constituent data

        def constituent_bytes
            out = String.new(encoding: Encoding::BINARY)
            out << pack_table(@constituents.map { |c| c[:speed] }, :speed)
            out << pack_table(@constituents.flat_map { |c| c[:equilibrium] }, :equilibrium)
            out << pack_table(@constituents.flat_map { |c| c[:node_factors] }, :node)
            out
        end

        def pack_table(values, name)
            p = @params
            bits = BitPacker.new
            values.each do |v|
                bits.write_uint(nint(v * p[:"#{name}_scale"]) - p[:"#{name}_offset"], p[:"#{name}_bits"], name)
            end
            bits.bytes
        rescue RangeError => e
            raise ArgumentError, "#{name} table: #{e.message} (scale #{p[:"#{name}_scale"]}, " \
                                 "offset #{p[:"#{name}_offset"]})"
        end

        # ---------------------------------------------------------------
        # Station records

        # Station values with table strings replaced by indexes, time offsets as
        # libtcd's signed HHMM, and nil replaced by libtcd's null values.
        def index_strings(s)
            label = field(s, :name).to_s
            type = int_value(field(s, :record_type) || (field(s, :amplitudes) ? 1 : 2), "#{label}: record_type")
            raise ArgumentError, "#{label}: record_type must be 1 (reference) or 2 (subordinate), got #{type}" unless [1, 2].include?(type)

            r = {
                record_type: type,
                latitude: float_value(field(s, :latitude), "#{label}: latitude"),
                longitude: float_value(field(s, :longitude), "#{label}: longitude"),
                tzfile: tz_index(field(s, :tzfile)),
                name: clip(field(s, :name)),
                reference_station: type == 1 ? -1 : int_value(field(s, :reference_station), "#{label}: reference_station"),
                country: table_index(:country, field(s, :country) || "Unknown"),
                source: clip(field(s, :source)),
                restriction: table_index(:restriction, field(s, :restriction) || @tables[:restriction].first),
                comments: clip(field(s, :comments)),
                notes: clip(field(s, :notes)),
                legalese: table_index(:legalese, field(s, :legalese) || @tables[:legalese].first),
                station_id_context: clip(field(s, :station_id_context)),
                station_id: clip(field(s, :station_id)),
                date_imported: date_value(field(s, :date_imported), "#{label}: date_imported"),
                xfields: field(s, :xfields).to_s,
                direction_units: table_index(:direction_unit, field(s, :direction_units) || "degrees true"),
                min_direction: direction_value(field(s, :min_direction), "#{label}: min_direction"),
                max_direction: direction_value(field(s, :max_direction), "#{label}: max_direction"),
                level_units: table_index(:level_unit, field(s, :level_units) || "Unknown")
            }
            raise ArgumentError, "station has no name" if r[:name].empty?
            raise ArgumentError, "#{r[:name]}: latitude out of range" unless r[:latitude].between?(-90, 90)
            raise ArgumentError, "#{r[:name]}: longitude out of range" unless r[:longitude].between?(-180, 180)
            check_length(r, :name, ONELINER_LENGTH)
            check_length(r, :source, ONELINER_LENGTH)
            check_length(r, :station_id_context, ONELINER_LENGTH)
            check_length(r, :station_id, ONELINER_LENGTH)
            check_length(r, :comments, MONOLOGUE_LENGTH)
            check_length(r, :notes, MONOLOGUE_LENGTH)
            check_length(r, :xfields, MONOLOGUE_LENGTH)

            if type == 1
                n = @constituents.size
                amplitudes = field(s, :amplitudes) || []
                epochs = field(s, :epochs) || []
                if amplitudes.size > n || epochs.size > n
                    raise ArgumentError, "#{r[:name]}: more amplitudes or epochs than the #{n} constituents"
                end
                r.merge!(
                    datum_offset: float_value(field(s, :datum_offset) || 0, "#{label}: datum_offset"),
                    datum: table_index(:datum, field(s, :datum) || "Unknown"),
                    zone_offset: hhmm_value(field(s, :zone_offset), "#{label}: zone_offset"),
                    expiration_date: date_value(field(s, :expiration_date), "#{label}: expiration_date"),
                    months_on_station: int_value(field(s, :months_on_station) || 0, "#{label}: months_on_station"),
                    last_date_on_station: date_value(field(s, :last_date_on_station), "#{label}: last_date_on_station"),
                    confidence: int_value(field(s, :confidence) || 0, "#{label}: confidence"),
                    amplitudes: Array.new(n) { |i| float_value(amplitudes[i] || 0, "#{label}: amplitude #{i}") },
                    epochs: Array.new(n) { |i| float_value(epochs[i] || 0, "#{label}: epoch #{i}") }
                )
                if r[:amplitudes].any?(&:negative?)
                    raise ArgumentError, "#{r[:name]}: negative amplitude"
                end
                # libtcd check_tide_record refuses epochs outside 0..360
                bad = r[:epochs].find { |e| !e.between?(0.0, 360.0) }
                raise ArgumentError, "#{r[:name]}: epoch #{bad} is outside 0..360 degrees" if bad
            else
                r.merge!(
                    min_time_add: hhmm(field(s, :min_time_add), "#{label}: min_time_add"),
                    min_level_add: float_value(field(s, :min_level_add) || 0, "#{label}: min_level_add"),
                    min_level_multiply: multiply_value(field(s, :min_level_multiply), "#{label}: min_level_multiply"),
                    max_time_add: hhmm(field(s, :max_time_add), "#{label}: max_time_add"),
                    max_level_add: float_value(field(s, :max_level_add) || 0, "#{label}: max_level_add"),
                    max_level_multiply: multiply_value(field(s, :max_level_multiply), "#{label}: max_level_multiply"),
                    flood_begins: (v = field(s, :flood_begins)).nil? ? NULL_SLACK_OFFSET : hhmm(v, "#{label}: flood_begins"),
                    ebb_begins: (v = field(s, :ebb_begins)).nil? ? NULL_SLACK_OFFSET : hhmm(v, "#{label}: ebb_begins")
                )
            end
            r
        end

        # Packs one record (libtcd pack_tide_record). Returns the bytes and the
        # bit positions of the two level-multiply fields (subordinate records).
        def pack_station(r, number)
            p = @params
            name = r[:name]
            fields = BitPacker.new
            fields.write_uint(0, p[:record_size_bits], "record size") # set by splice_bits
            fields.write_uint(r[:record_type], p[:record_type_bits], "record type")
            fields.write_int(nint(r[:latitude] * p[:latitude_scale]), p[:latitude_bits], "latitude")
            fields.write_int(nint(r[:longitude] * p[:longitude_scale]), p[:longitude_bits], "longitude")
            fields.write_uint(r[:tzfile], p[:tzfile_bits], "tzfile")
            fields.write_string(latin1(name, "name"))
            fields.write_int(r[:reference_station], p[:station_bits], "reference station")
            fields.write_uint(r[:country], p[:country_bits], "country")
            fields.write_string(latin1(r[:source], "source"))
            fields.write_uint(r[:restriction], p[:restriction_bits], "restriction")
            fields.write_string(latin1(r[:comments], "comments"))
            fields.write_string(latin1(r[:notes], "notes"))
            fields.write_uint(r[:legalese], p[:legalese_bits], "legalese")
            fields.write_string(latin1(r[:station_id_context], "station_id_context"))
            fields.write_string(latin1(r[:station_id], "station_id"))
            fields.write_uint(r[:date_imported], p[:date_bits], "date imported")
            fields.write_string(latin1(r[:xfields], "xfields"))
            fields.write_uint(r[:direction_units], p[:direction_unit_bits], "direction units")
            fields.write_uint(r[:min_direction], p[:direction_bits], "min direction")
            fields.write_uint(r[:max_direction], p[:direction_bits], "max direction")
            fields.write_uint(r[:level_units], p[:level_unit_bits], "level units")

            multiply_positions = nil
            if r[:record_type] == 1
                fields.write_int(nint(r[:datum_offset] * p[:datum_offset_scale]), p[:datum_offset_bits], "datum offset")
                fields.write_uint(r[:datum], p[:datum_bits], "datum")
                fields.write_int(r[:zone_offset], p[:time_bits], "zone offset")
                fields.write_uint(r[:expiration_date], p[:date_bits], "expiration date")
                fields.write_uint(r[:months_on_station], p[:months_on_station_bits], "months on station")
                fields.write_uint(r[:last_date_on_station], p[:date_bits], "last date on station")
                fields.write_uint(r[:confidence], p[:confidence_value_bits], "confidence")
                used = r[:amplitudes].each_index.select { |i| r[:amplitudes][i] >= AMPLITUDE_EPSILON }
                fields.write_uint(used.size, p[:constituent_bits], "constituent count")
                used.each do |i|
                    fields.write_uint(i, p[:constituent_bits], "constituent index")
                    fields.write_uint(nint(r[:amplitudes][i] * p[:amplitude_scale]), p[:amplitude_bits], "amplitude")
                    fields.write_uint(nint(r[:epochs][i] * p[:epoch_scale]), p[:epoch_bits], "epoch")
                end
            else
                fields.write_int(r[:min_time_add], p[:time_bits], "min time add")
                fields.write_int(nint(r[:min_level_add] * p[:level_add_scale]), p[:level_add_bits], "min level add")
                min_pos = fields.bit_length
                fields.write_uint(nint(r[:min_level_multiply] * p[:level_multiply_scale]), p[:level_multiply_bits],
                                  "min level multiply")
                fields.write_int(r[:max_time_add], p[:time_bits], "max time add")
                fields.write_int(nint(r[:max_level_add] * p[:level_add_scale]), p[:level_add_bits], "max level add")
                max_pos = fields.bit_length
                fields.write_uint(nint(r[:max_level_multiply] * p[:level_multiply_scale]), p[:level_multiply_bits],
                                  "max level multiply")
                fields.write_int(r[:flood_begins], p[:time_bits], "flood begins")
                fields.write_int(r[:ebb_begins], p[:time_bits], "ebb begins")
                multiply_positions = [min_pos, max_pos]
            end

            bytes = fields.bytes
            if bytes.bytesize >= (1 << p[:record_size_bits])
                raise ArgumentError, "#{name}: record #{number} is #{bytes.bytesize} bytes, over record_size_bits"
            end
            [splice_bits(bytes, bytes.bytesize, p[:record_size_bits]), multiply_positions]
        rescue RangeError => e
            raise ArgumentError, "#{r[:name]}: #{e.message}"
        end

        # Writes the record size into the first bits of the packed record.
        def splice_bits(bytes, size_value, bits)
            n = bytes.unpack1("B*")
            n[0, bits] = size_value.to_s(2).rjust(bits, "0")
            [n].pack("B*")
        end

        # The reader returns 1.0 for a stored level multiply of 0 (XTide's
        # meaning). To copy such a record exactly, read the stored value back
        # from the source file.
        def restore_null_multipliers(station, io, offset)
            return station unless station.respond_to?(:subordinate?) && station.subordinate?
            return station unless station.min_level_multiply == 1.0 || station.max_level_multiply == 1.0

            @params ||= compute_params
            r = index_strings(station)
            _bytes, positions = pack_station(r, station.record_number)
            io.seek(offset)
            stored = io.read(station.record_size).unpack1("B*")
            bits = @params[:level_multiply_bits]
            copy = station.dup
            copy.min_level_multiply = 0.0 if stored[positions[0], bits].to_i(2).zero?
            copy.max_level_multiply = 0.0 if stored[positions[1], bits].to_i(2).zero?
            copy
        ensure
            @params = nil
        end

        # ---------------------------------------------------------------
        # Helpers

        def normalize_constituent(c)
            {
                name: field(c, :name).to_s,
                speed: float_value(field(c, :speed), "constituent #{field(c, :name)}: speed"),
                equilibrium: Array(field(c, :equilibrium)).map { |v| float_value(v, "constituent #{field(c, :name)}: equilibrium") },
                node_factors: Array(field(c, :node_factors)).map { |v| float_value(v, "constituent #{field(c, :name)}: node factor") }
            }
        end

        def field(obj, key)
            if obj.is_a?(Hash)
                obj.key?(key) ? obj[key] : obj[key.to_s]
            elsif obj.respond_to?(key)
                obj.public_send(key)
            end
        end

        # Index of a string in a table, appending it when absent.
        def table_index(table, value)
            entries = @tables[table]
            idx = entries.index(value)
            return idx if idx

            entries << value
            entries.size - 1
        end

        # Time zones are stored with a leading ':' (":America/New_York"); the reader
        # strips it. Table entries are kept as given ("Unknown" has none).
        def tz_index(tz)
            raise ArgumentError, "station has no time zone" if tz.nil? || tz.to_s.empty?

            tz = tz.to_s
            @tables[:tzfile].index(tz) || @tables[:tzfile].index(":#{tz}") ||
                table_index(:tzfile, tz.start_with?(":") ? tz : ":#{tz}")
        end

        # libtcd clip_string: drop leading spaces, trailing spaces, CR and LF
        def clip(value)
            value.to_s.sub(/\A +/, "").sub(/[ \r\n]+\z/, "")
        end

        def check_length(r, key, limit)
            bytes = latin1(r[key], key.to_s)
            return if bytes.bytesize < limit

            raise ArgumentError, "#{r[:name]}: #{key} is #{bytes.bytesize} bytes; libtcd allows #{limit - 1}"
        end

        # libtcd strings are NUL-terminated, so a NUL would cut the string short
        # and shift every field after it.
        def latin1(value, what)
            str = value.to_s
            raise ArgumentError, "#{what} #{str.inspect} contains a NUL byte" if str.b.include?("\0")

            str.encode(Encoding::ISO_8859_1).force_encoding(Encoding::BINARY)
        rescue EncodingError
            raise ArgumentError, "#{what} #{value.to_s.inspect} has characters outside ISO-8859-1"
        end

        # A header value libtcd reads back unchanged: one line, no control
        # characters, no "[" or "]" (libtcd matches "[KEY]" anywhere in a line),
        # no leading or trailing spaces (libtcd strips them).
        def header_text(value, what)
            str = value.to_s
            if str.match?(/[\x00-\x1f\x7f\[\]]/) || str != str.strip
                raise ArgumentError, "#{what} #{str.inspect} has a control character, a bracket, or " \
                                     "leading/trailing space; libtcd would read the header differently"
            end
            latin1(str, what)
            str
        end

        # An integer field: an Integer, or a Float with no fractional part.
        def int_value(value, what)
            case value
            when Integer
                value
            when Float
                unless value.finite? && value == value.truncate
                    raise ArgumentError, "#{what} must be a whole number, got #{value}"
                end
                value.to_i
            when nil
                raise ArgumentError, "#{what} is missing"
            else
                raise ArgumentError, "#{what} must be an integer, got #{value.inspect}"
            end
        end

        def float_value(value, what)
            raise ArgumentError, "#{what} must be a number, got #{value.inspect}" unless value.is_a?(Numeric)

            f = value.to_f
            raise ArgumentError, "#{what} must be finite, got #{f}" unless f.finite?
            f
        end

        # libtcd check_date: 0, or YYYYMMDD with month 1..12 and day 1..31
        def date_value(value, what)
            date = int_value(value || 0, what)
            return date if date.zero?

            md = date % 10_000
            unless date.positive? && (md / 100).between?(1, 12) && (md % 100).between?(1, 31)
                raise ArgumentError, "#{what} #{date} is not 0 or a YYYYMMDD date"
            end
            date
        end

        # 0..360 degrees, nil for none (stored as 361)
        def direction_value(value, what)
            return NULL_DIRECTION if value.nil?

            dir = int_value(value, what)
            raise ArgumentError, "#{what} #{dir} is outside 0..#{NULL_DIRECTION}" unless dir.between?(0, NULL_DIRECTION)
            dir
        end

        # zone_offset is libtcd's signed HHMM (e.g. -500 for UTC-5, 530 for UTC+5:30), not minutes
        def hhmm_value(value, what)
            v = int_value(value || 0, what)
            unless v.between?(-4096, 4095) && v.abs % 100 < 60
                raise ArgumentError, "#{what} #{v} is not a signed HHMM value (-4096..4095, minutes < 60)"
            end
            v
        end

        # 0 means "none" (XTide treats it as 1.0); a positive value too small
        # to store would silently become that 0.
        def multiply_value(value, what)
            m = float_value(value || 0, what)
            raise ArgumentError, "#{what} #{m} is negative" if m.negative?
            if m.positive? && nint(m * @multiply_scale).zero?
                raise ArgumentError, "#{what} #{m} rounds to 0, which libtcd and XTide read as no multiplier"
            end
            m
        end

        # Minutes (the reader's unit) to libtcd's signed HHMM
        def hhmm(minutes, what = "time offset")
            m = int_value(minutes || 0, what)
            sign = m.negative? ? -1 : 1
            m = m.abs
            sign * ((m / 60) * 100 + m % 60)
        end

        # libtcd NINT: round half away from zero
        def nint(value)
            value.negative? ? (value - 0.5).to_i : (value + 0.5).to_i
        end

        # libtcd calculate_bits: bits needed to store value (0 for 0)
        def calculate_bits(value)
            value.zero? ? 0 : value.bit_length
        end

        # Bit-level output, most significant bit first, padded with zero bits to
        # a whole byte: the mirror of BitBuffer.
        class BitPacker
            def initialize
                @out = String.new(encoding: Encoding::BINARY)
                @acc = 0
                @nbits = 0
                @total = 0
            end

            def bit_length
                @total
            end

            def write_uint(value, bits, what)
                value = Integer(value)
                if value.negative? || value >= (1 << bits)
                    raise RangeError, "#{what} value #{value} does not fit #{bits} unsigned bits"
                end
                put(value, bits)
            end

            def write_int(value, bits, what)
                value = Integer(value)
                half = 1 << (bits - 1)
                unless value >= -half && value < half
                    raise RangeError, "#{what} value #{value} does not fit #{bits} signed bits"
                end
                put(value & ((1 << bits) - 1), bits)
            end

            def write_string(bytes)
                bytes.each_byte { |b| put(b, 8) }
                put(0, 8)
            end

            def bytes
                out = @out.dup
                out << ((@acc << (8 - @nbits)) & 0xFF).chr if @nbits.positive?
                out
            end

            private

            def put(value, bits)
                return if bits.zero?

                @acc = (@acc << bits) | value
                @nbits += bits
                @total += bits
                while @nbits >= 8
                    @nbits -= 8
                    @out << ((@acc >> @nbits) & 0xFF).chr
                end
                @acc &= (1 << @nbits) - 1
            end
        end
    end
end
