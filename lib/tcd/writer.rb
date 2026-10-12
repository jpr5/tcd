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

            @start_year = Integer(start_year)
            @number_of_years = number_of_years ? Integer(number_of_years) : @constituents.first[:equilibrium].size
            @constituents.each do |c|
                [:equilibrium, :node_factors].each do |key|
                    next if c[key].size == @number_of_years
                    raise ArgumentError, "constituent #{c[:name]}: #{c[key].size} #{key} values for #{@number_of_years} years"
                end
            end
            @version = version || LIBTCD_VERSION
            @last_modified = last_modified
            @given_params = params.transform_keys(&:to_sym)
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
                if r[:record_type] == 2 && !r[:reference_station].between?(0, records.size - 1)
                    raise ArgumentError, "#{r[:name]}: reference_station #{r[:reference_station]} is not a record index"
                end
                body << pack_station(r, i).first
            end

            header = header_bytes(@params[:header_size] + 4 + body.bytesize)
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
            p = DEFAULTS.merge(@given_params)

            speeds = @constituents.map { |c| c[:speed] }
            if speeds.any?(&:negative?)
                raise ArgumentError, "negative constituent speed"
            end
            if @constituents.any? { |c| c[:node_factors].any? { |f| f <= 0 } }
                raise ArgumentError, "node factors must be positive"
            end
            derive_range(p, :speed, speeds)
            derive_range(p, :equilibrium, @constituents.flat_map { |c| c[:equilibrium] })
            derive_range(p, :node, @constituents.flat_map { |c| c[:node_factors] })

            # A reference record stores the count of its constituents in
            # constituent_bits, so the count itself must fit.
            p[:constituent_bits] = [p[:constituent_bits] || 0, calculate_bits(@constituents.size)].max
            p[:level_unit_bits] = [p[:level_unit_bits] || 0, calculate_bits(@tables[:level_unit].size - 1)].max
            p[:direction_unit_bits] = [p[:direction_unit_bits] || 0,
                                       calculate_bits(@tables[:direction_unit].size - 1)].max
            # The padded tables need room for "__END__" after the last entry.
            %i[restriction tzfile country datum legalese].each do |t|
                key = :"#{t}_bits"
                p[key] = [p[key], calculate_bits(@tables[t].size)].max
            end
            # reference_station is signed and holds record indexes
            p[:station_bits] = [p[:station_bits], calculate_bits(@stations.size) + 1].max
            p
        end

        # Offset and width for one bit-packed constituent table, from the data
        # range unless given.
        def derive_range(p, name, values)
            scale = p[:"#{name}_scale"]
            p[:"#{name}_offset"] ||= nint(values.min * scale)
            p[:"#{name}_bits"] ||= [calculate_bits(nint(values.max * scale) - p[:"#{name}_offset"]), 1].max
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
            out << table_entry(END_MARKER, size, what)
            out << ("\0" * ((max - entries.size - 1) * size))
        end

        def table_entry(value, size, what)
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
        end

        # ---------------------------------------------------------------
        # Station records

        # Station values with table strings replaced by indexes, time offsets as
        # libtcd's signed HHMM, and nil replaced by libtcd's null values.
        def index_strings(s)
            type = field(s, :record_type) || (field(s, :amplitudes) ? 1 : 2)
            r = {
                record_type: type,
                latitude: Float(field(s, :latitude)),
                longitude: Float(field(s, :longitude)),
                tzfile: tz_index(field(s, :tzfile)),
                name: clip(field(s, :name)),
                reference_station: type == 1 ? -1 : Integer(field(s, :reference_station)),
                country: table_index(:country, field(s, :country) || "Unknown"),
                source: clip(field(s, :source)),
                restriction: table_index(:restriction, field(s, :restriction) || @tables[:restriction].first),
                comments: clip(field(s, :comments)),
                notes: clip(field(s, :notes)),
                legalese: table_index(:legalese, field(s, :legalese) || @tables[:legalese].first),
                station_id_context: clip(field(s, :station_id_context)),
                station_id: clip(field(s, :station_id)),
                date_imported: field(s, :date_imported) || 0,
                xfields: field(s, :xfields).to_s,
                direction_units: table_index(:direction_unit, field(s, :direction_units) || "degrees true"),
                min_direction: field(s, :min_direction) || NULL_DIRECTION,
                max_direction: field(s, :max_direction) || NULL_DIRECTION,
                level_units: table_index(:level_unit, field(s, :level_units) || "Unknown")
            }
            raise ArgumentError, "station has no name" if r[:name].empty?
            raise ArgumentError, "#{r[:name]}: record_type must be 1 or 2" unless [1, 2].include?(type)
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
                    datum_offset: Float(field(s, :datum_offset) || 0),
                    datum: table_index(:datum, field(s, :datum) || "Unknown"),
                    zone_offset: field(s, :zone_offset) || 0,
                    expiration_date: field(s, :expiration_date) || 0,
                    months_on_station: field(s, :months_on_station) || 0,
                    last_date_on_station: field(s, :last_date_on_station) || 0,
                    confidence: field(s, :confidence) || 0,
                    amplitudes: Array.new(n) { |i| Float(amplitudes[i] || 0) },
                    epochs: Array.new(n) { |i| Float(epochs[i] || 0) }
                )
                if r[:amplitudes].any?(&:negative?)
                    raise ArgumentError, "#{r[:name]}: negative amplitude"
                end
            else
                r.merge!(
                    min_time_add: hhmm(field(s, :min_time_add)),
                    min_level_add: Float(field(s, :min_level_add) || 0),
                    min_level_multiply: Float(field(s, :min_level_multiply) || 0),
                    max_time_add: hhmm(field(s, :max_time_add)),
                    max_level_add: Float(field(s, :max_level_add) || 0),
                    max_level_multiply: Float(field(s, :max_level_multiply) || 0),
                    flood_begins: (v = field(s, :flood_begins)).nil? ? NULL_SLACK_OFFSET : hhmm(v),
                    ebb_begins: (v = field(s, :ebb_begins)).nil? ? NULL_SLACK_OFFSET : hhmm(v)
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
                speed: Float(field(c, :speed)),
                equilibrium: field(c, :equilibrium).map { |v| Float(v) },
                node_factors: field(c, :node_factors).map { |v| Float(v) }
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

        def latin1(value, what)
            value.to_s.encode(Encoding::ISO_8859_1).force_encoding(Encoding::BINARY)
        rescue EncodingError
            raise ArgumentError, "#{what} #{value.to_s.inspect} has characters outside ISO-8859-1"
        end

        # Minutes (the reader's unit) to libtcd's signed HHMM
        def hhmm(minutes)
            m = Integer(minutes || 0)
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
