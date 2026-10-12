# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "open3"

# The writer must never produce a file that libtcd or XTide reads wrong or
# aborts on, or that the gem cannot read back: each case below either raises
# ArgumentError or writes a correct file.
class WriterValidationTest < Minitest::Test
    M2 = { name: "M2", speed: 28.9841042, equilibrium: [10.0, 20.0], node_factors: [1.0, 1.01] }.freeze
    K1 = { name: "K1", speed: 15.0410686, equilibrium: [30.0, 40.0], node_factors: [0.99, 1.0] }.freeze

    def writer(constituents: [M2, K1], **kw)
        TCD::Writer.new(constituents: constituents, start_year: 2025, **kw)
    end

    def ref(over = {})
        { name: "Ref", latitude: 41.5, longitude: -70.6, tzfile: "America/New_York", level_units: "meters",
          zone_offset: -500, amplitudes: [0.5, 0.2], epochs: [120.0, 150.5] }.merge(over)
    end

    def sub(over = {})
        { name: "Sub", record_type: 2, latitude: 41.6, longitude: -70.5, tzfile: "America/New_York",
          reference_station: 0, level_units: "meters", min_time_add: 30, max_time_add: -15,
          min_level_multiply: 0.9, max_level_multiply: 1.1 }.merge(over)
    end

    def refuses(pattern, &block)
        err = assert_raises(ArgumentError, &block)
        assert_match pattern, err.message
    end

    def write_and_read(w)
        Dir.mktmpdir do |dir|
            path = File.join(dir, "t.tcd")
            w.write(path)
            TCD.open(path) { |db| yield db, path }
        end
    end

    # 1. NUL
    def test_nul_in_station_string
        refuses(/name .* contains a NUL byte/) { writer.add_station(ref(name: "A\0B")).to_bytes }
        refuses(/comments .* contains a NUL byte/) { writer.add_station(ref(comments: "a\0b")).to_bytes }
        refuses(/xfields .* contains a NUL byte/) { writer.add_station(ref(xfields: "k:v\0x")).to_bytes }
    end

    def test_nul_in_table_entry
        refuses(/country .* contains a NUL byte/) { writer(countries: ["Unknown", "A\0B"]).add_station(ref).to_bytes }
        refuses(/contains a NUL byte/) { writer.add_station(ref(datum: "D\0")).to_bytes }
    end

    # 2. "__END__"
    def test_end_marker_entries
        %i[country datum restriction legalese level_units direction_units].each do |key|
            refuses(/"__END__" would end the table/) { writer.add_station(ref(key => "__END__")).to_bytes }
        end
    end

    # 3. table limits
    def test_byte_indexed_tables_limited_to_256
        refuses(/257 level_unit table entries; libtcd allows at most 256/) do
            writer(level_units: Array.new(257) { |i| "U#{i}" }).add_station(ref(level_units: "U1")).to_bytes
        end
        refuses(/257 restriction table entries/) do
            writer(restrictions: Array.new(257) { |i| "R#{i}" }).add_station(ref(restriction: "R1")).to_bytes
        end
        refuses(/257 legalese table entries/) do
            writer(legaleses: Array.new(257) { |i| "L#{i}" }).add_station(ref(legalese: "L1")).to_bytes
        end
        refuses(/257 direction_unit table entries/) do
            writer(direction_units: ["Unknown", "degrees true"] + Array.new(255) { |i| "D#{i}" }).add_station(ref).to_bytes
        end
        # 256 is the most: the last index (255) still fits libtcd's byte
        w = writer(level_units: Array.new(256) { |i| "U#{i}" }).add_station(ref(level_units: "U255"))
        write_and_read(w) { |db| assert_equal "U255", db.stations[0].level_units }
    end

    def test_int16_indexed_tables_limited_to_32768
        refuses(/32769 tzfile table entries; libtcd allows at most 32768/) do
            writer(timezones: Array.new(32_769) { |i| ":Z/#{i}" }).add_station(ref(tzfile: "Z/1")).to_bytes
        end
        refuses(/32769 country table entries/) do
            writer(countries: Array.new(32_769) { |i| "C#{i}" }).add_station(ref(country: "C1")).to_bytes
        end
    end

    # 4. header injection
    def test_header_values
        ["x\n[NUMBER OF RECORDS] = 0", "abc\r", "a\tb", "ab\0cd", "1 [MAJOR REV]", "x]", " lead", "trail "].each do |v|
            refuses(/version .* libtcd would read the header differently/) { writer(version: v) }
            refuses(/last_modified .* libtcd would read the header differently/) { writer(last_modified: v) }
        end
        write_and_read(writer(version: "OTC tcd-writer 1.1", last_modified: "2026-10-11 00:00 UTC").add_station(ref)) do |db|
            assert_equal "OTC tcd-writer 1.1", db.version
            assert_equal "2026-10-11 00:00 UTC", db.last_modified
        end
    end

    # 5. no float truncation
    def test_integer_fields_refuse_fractions
        refuses(/start_year must be a whole number, got 2020.7/) { TCD::Writer.new(constituents: [M2], start_year: 2020.7) }
        refuses(/number_of_years must be a whole number/) { TCD::Writer.new(constituents: [M2], start_year: 2020, number_of_years: 2.5) }
        refuses(/min_time_add must be a whole number, got 10.9/) { writer.add_station(ref).add_station(sub(min_time_add: 10.9)).to_bytes }
        refuses(/flood_begins must be a whole number/) { writer.add_station(ref).add_station(sub(flood_begins: 30.7)).to_bytes }
        refuses(/min_direction must be a whole number/) { writer.add_station(ref(min_direction: 10.9)).to_bytes }
        refuses(/reference_station must be a whole number/) { writer.add_station(ref).add_station(sub(reference_station: 0.5)).to_bytes }
        refuses(/zone_offset must be a whole number/) { writer.add_station(ref(zone_offset: -500.5)).to_bytes }
        refuses(/confidence must be an integer/) { writer.add_station(ref(confidence: "3")).to_bytes }
        refuses(/header parameter amplitude_bits must be a whole number/) { writer(params: { amplitude_bits: 19.5 }) .add_station(ref).to_bytes }
        refuses(/epoch 0 must be finite/) { writer.add_station(ref(epochs: [Float::NAN, 0])).to_bytes }
    end

    def test_integral_floats_are_accepted
        w = writer.add_station(ref(zone_offset: -500.0, min_direction: 10.0, max_direction: 190.0))
                  .add_station(sub(reference_station: 0.0, min_time_add: 30.0))
        write_and_read(w) do |db|
            assert_equal(-500, db.stations[0].zone_offset)
            assert_equal 10, db.stations[0].min_direction
            assert_equal 30, db.stations[1].min_time_add
        end
    end

    # 6. 32-bit limits
    def test_wide_speed_range_chooses_a_scale_that_fits
        z0 = { name: "Z0", speed: 0.0, equilibrium: [0.0, 0.0], node_factors: [1.0, 1.0] }
        m8 = { name: "M8", speed: 231.8728336, equilibrium: [10.0, 20.0], node_factors: [1.0, 1.0] }
        w = writer(constituents: [z0, m8]).add_station(ref(amplitudes: [0.1, 0.2], epochs: [0, 10]))
        write_and_read(w) do |db|
            assert_operator db.header.speed_bits, :<=, 31
            assert_equal 1_000_000, db.header.speed_scale
            assert_in_delta 231.872834, db.constituent("M8").speed, 1e-9
            assert_equal 0.0, db.constituent("Z0").speed
        end
    end

    def test_values_that_cannot_be_stored
        refuses(/node values .* need 34 bits .* at most 31/) do
            writer(constituents: [M2.merge(node_factors: [1e6, 1.0])]).to_bytes
        end
        refuses(/equilibrium arguments must be >= 0/) { writer(constituents: [M2.merge(equilibrium: [-1.0, 2.0])]).to_bytes }
        refuses(/speed_bits = 32 is out of range/) { writer(params: { speed_bits: 32 }).to_bytes }
        refuses(/amplitude_bits = 0 is out of range/) { writer(params: { amplitude_bits: 0 }).to_bytes }
        refuses(/amplitude_scale = 0 is out of range/) { writer(params: { amplitude_scale: 0 }).to_bytes }
        refuses(/speed_offset = -1 is out of range/) { writer(params: { speed_offset: -1 }).to_bytes }
        refuses(/unknown header parameters: bogus/) { writer(params: { bogus: 1 }) }
        refuses(/start_year 2147483648 is outside libtcd's 32-bit range/) { TCD::Writer.new(constituents: [M2], start_year: 2**31) }
    end

    # L1. one-entry unit tables
    def test_one_entry_level_unit_table_is_readable
        w = writer(level_units: ["meters"]).add_station(ref)
        write_and_read(w) do |db|
            assert_equal 1, db.header.level_unit_bits
            assert_equal "meters", db.stations[0].level_units
        end
    end

    # L2. "degrees true"
    def test_direction_units_need_degrees_true_after_first_entry
        refuses(/must contain "degrees true" after its first entry/) { writer(direction_units: ["degrees true"]).add_station(ref).to_bytes }
        refuses(/must contain "degrees true"/) do
            writer(direction_units: ["Unknown", "degrees"]).add_station(ref(direction_units: "degrees")).to_bytes
        end
    end

    # L3. subordinate references
    def test_subordinate_reference_must_be_a_reference_record
        refuses(/reference_station 1 is not a reference \(type 1\) record/) do
            writer.add_station(ref).add_station(sub(reference_station: 1)).to_bytes
        end
        refuses(/Sub2: reference_station 1 is not a reference/) do
            writer.add_station(ref).add_station(sub).add_station(sub(name: "Sub2", reference_station: 1)).to_bytes
        end
        refuses(/reference_station 5 is not a record index/) { writer.add_station(ref).add_station(sub(reference_station: 5)).to_bytes }
    end

    # L4. ArgumentError with a clear message
    def test_clear_errors
        refuses(/speed table: speed value .* does not fit 3 unsigned bits/) do
            writer(params: { speed_bits: 3 }).to_bytes
        end
        refuses(/Sub: reference_station is missing/) { writer.add_station(ref).add_station(sub(reference_station: nil)).to_bytes }
        refuses(/record_type must be 1 \(reference\) or 2 \(subordinate\), got 3/) { writer.add_station(ref(record_type: 3)).to_bytes }
        refuses(/number_of_years must be at least 1, got 0/) do
            TCD::Writer.new(constituents: [M2.merge(equilibrium: [], node_factors: [])], start_year: 2025, number_of_years: 0)
        end
    end

    # Docs items: zone_offset HHMM, dates, epochs
    def test_zone_offset_is_hhmm
        refuses(/zone_offset -560 is not a signed HHMM value/) { writer.add_station(ref(zone_offset: -560)).to_bytes }
        refuses(/zone_offset 4096 is not a signed HHMM/) { writer.add_station(ref(zone_offset: 4096)).to_bytes }
        write_and_read(writer.add_station(ref(zone_offset: 530))) { |db| assert_equal 530, db.stations[0].zone_offset }
    end

    def test_dates
        refuses(/date_imported 20261301 is not 0 or a YYYYMMDD date/) { writer.add_station(ref(date_imported: 20_261_301)).to_bytes }
        refuses(/expiration_date 20260100 is not 0 or a YYYYMMDD date/) { writer.add_station(ref(expiration_date: 20_260_100)).to_bytes }
        write_and_read(writer.add_station(ref(date_imported: 20_261_011))) { |db| assert_equal 20_261_011, db.stations[0].date_imported }
    end

    def test_epochs_outside_0_to_360
        refuses(/epoch 400.0 is outside 0..360/) { writer.add_station(ref(epochs: [400.0, 0])).to_bytes }
        refuses(/epoch -0.5 is outside 0..360/) { writer.add_station(ref(epochs: [-0.5, 0])).to_bytes }
        write_and_read(writer.add_station(ref(epochs: [360.0, 0]))) { |db| assert_equal 360.0, db.stations[0].epochs[0] }
    end

    def test_multiplier_that_would_round_to_none
        refuses(/min_level_multiply 0.0004 rounds to 0/) { writer.add_station(ref).add_station(sub(min_level_multiply: 0.0004)).to_bytes }
    end

    # libtcd-backed: set TCD_LIBTCD_DUMP to a binary built from
    # test/fixtures/tcd_fulldump.c against libtcd; skipped otherwise.
    def test_libtcd_reads_written_files
        dump = ENV["TCD_LIBTCD_DUMP"]
        skip "set TCD_LIBTCD_DUMP to run libtcd checks" unless dump && File.executable?(dump)

        z0 = { name: "Z0", speed: 0.0, equilibrium: [0.0, 0.0], node_factors: [1.0, 1.0] }
        m8 = { name: "M8", speed: 231.8728336, equilibrium: [10.0, 20.0], node_factors: [1.0, 1.0] }
        cases = {
            "wide speeds" => [writer(constituents: [z0, m8]).add_station(ref(amplitudes: [0.1, 0.2], epochs: [0, 10])),
                              ["constituent[1]=M8 speed=231.8728340"]],
            "one level unit" => [writer(level_units: ["meters"]).add_station(ref),
                                 ["level_units=0:meters"]],
            "256 level units" => [writer(level_units: Array.new(256) { |i| "U#{i}" }).add_station(ref(level_units: "U255")),
                                  ["level_units=255:U255"]],
            "subordinate" => [writer.add_station(ref).add_station(sub(min_time_add: 90, flood_begins: -45)),
                              ["min_time_add=130", "flood_begins=-45", "min_level_multiply=0.900"]],
            "hhmm and dates" => [writer.add_station(ref(zone_offset: 530, date_imported: 20_261_011, epochs: [360.0, 0])),
                                 ["zone_offset=530", "date_imported=20261011", "c[0]=0.5000,360.00"]]
        }
        Dir.mktmpdir do |dir|
            cases.each do |label, (w, expected)|
                path = File.join(dir, "#{label.tr(' ', '_')}.tcd")
                w.write(path)
                out, err, status = Open3.capture3(dump, path)
                assert status.success?, "#{label}: libtcd failed: #{err}"
                assert_empty err, label
                expected.each { |e| assert_includes out, e, label }
            end
        end
    end
end
