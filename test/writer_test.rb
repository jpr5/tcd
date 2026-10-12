# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class WriterTest < Minitest::Test
    UNALIGNED = File.expand_path("fixtures/unaligned-11.tcd", __dir__)

    def round_trip(path)
        TCD.open(path) { |db| TCD::Writer.from_reader(db).to_bytes }
    end

    def read_bytes(bytes)
        Dir.mktmpdir do |dir|
            path = File.join(dir, "written.tcd")
            File.binwrite(path, bytes)
            TCD.open(path) { |db| yield db }
        end
    end

    def assert_same_database(expected_path, actual_bytes)
        TCD.open(expected_path) do |want|
            read_bytes(actual_bytes) do |got|
                assert_equal want.header.params, got.header.params
                %i[level_units direction_units restrictions timezones countries datums legalese constituents].each do |t|
                    assert_equal want.lookup_tables.public_send(t), got.lookup_tables.public_send(t), t
                end
                assert_equal want.constituents.map(&:to_h), got.constituents.map(&:to_h)
                assert_equal want.station_count, got.station_count
                want.stations.zip(got.stations) { |a, b| assert_equal a.to_h, b.to_h, a.name }
            end
        end
    end

    # libtcd wrote this file; the writer reproduces it byte for byte. Its
    # constituent tables end part-way through a byte.
    def test_round_trip_of_libtcd_file_with_unaligned_tables_is_byte_identical
        bytes = round_trip(UNALIGNED)
        assert_equal File.binread(UNALIGNED).bytes, bytes.bytes
        assert_same_database(UNALIGNED, bytes)
    end

    def test_round_trip_of_xtide_file
        bytes = round_trip(TCD_TEST_FILE)
        assert_same_database(TCD_TEST_FILE, bytes)
        assert_equal File.size(TCD_TEST_FILE), bytes.bytesize
        assert File.binread(TCD_TEST_FILE) == bytes, "written file differs from the original"
    end

    def test_header_checksum_is_crc32_of_padded_header_big_endian
        bytes = round_trip(UNALIGNED)
        size = 4096
        assert_equal Zlib.crc32(bytes[0, size]), bytes[size, 4].unpack1("N")
        assert_equal bytes.bytesize, bytes[/\[END OF FILE\] = (\d+)/, 1].to_i
    end

    def test_plain_data
        writer = TCD::Writer.new(
            constituents: [
                { name: "M2", speed: 28.9841042, equilibrium: [10.5, 200.25], node_factors: [0.98, 1.02] },
                { name: "S2", speed: 30.0, equilibrium: [0.0, 359.99], node_factors: [1.0, 1.0] },
                { name: "K1", speed: 15.0410686, equilibrium: [123.45, 67.89], node_factors: [1.1, 0.9] }
            ],
            start_year: 2025,
            countries: ["Unknown", "Norway"],
            datums: ["Unknown", "Lowest Astronomical Tide"]
        )
        writer.add_station(
            name: "Reference Ø", latitude: 59.9, longitude: 10.75, tzfile: "Europe/Oslo",
            country: "Norway", level_units: "meters", datum: "Lowest Astronomical Tide",
            datum_offset: 0.95, zone_offset: 100, station_id_context: "OTC", station_id: "OTC-1",
            amplitudes: [0.5, 0.2, 0.0], epochs: [120.0, 150.5, 0.0]
        )
        writer.add_station(
            name: "Current sub", latitude: 59.8, longitude: 10.7, tzfile: ":Europe/Oslo",
            reference_station: 0, level_units: "knots", min_direction: 10, max_direction: 190,
            min_time_add: -75, max_time_add: 30, min_level_multiply: 0.8, max_level_multiply: 1.25,
            flood_begins: 15, ebb_begins: nil
        )
        read_bytes(writer.to_bytes) do |db|
            assert_equal 3, db.constituent_count
            assert_equal 2025..2026, db.year_range
            m2 = db.constituent("M2")
            assert_in_delta 28.9841042, m2.speed, 1e-9
            assert_equal [10.5, 200.25], m2.equilibrium.map { |v| v.round(2) }
            assert_equal [0.98, 1.02], m2.node_factors.map { |v| v.round(4) }
            assert_equal [123.45, 67.89], db.constituent("K1").equilibrium.map { |v| v.round(2) }
            assert_equal [":Europe/Oslo"], db.lookup_tables.timezones

            ref, sub = db.stations
            assert ref.reference?
            assert_equal "Reference Ø", ref.name
            assert_equal "Europe/Oslo", ref.tzfile
            assert_equal "Norway", ref.country
            assert_equal "Lowest Astronomical Tide", ref.datum
            assert_in_delta 0.95, ref.datum_offset, 1e-9
            assert_equal 100, ref.zone_offset
            assert_equal "OTC-1", ref.station_id
            assert_equal [0.5, 0.2, 0.0], ref.amplitudes
            assert_equal [120.0, 150.5, 0.0], ref.epochs

            assert sub.subordinate?
            assert sub.current?
            assert_equal 0, sub.reference_station
            assert_equal "knots", sub.level_units
            assert_equal [10, 190], [sub.min_direction, sub.max_direction]
            assert_equal [-75, 30], [sub.min_time_add, sub.max_time_add]
            assert_in_delta 1.25, sub.max_level_multiply, 1e-9
            assert_equal 15, sub.flood_begins
            assert_nil sub.ebb_begins
        end
    end

    def small_writer
        TCD::Writer.new(constituents: [{ name: "M2", speed: 28.9841042, equilibrium: [1.0], node_factors: [1.0] }],
                        start_year: 2025)
    end

    def test_rejects_overlong_name
        w = small_writer.add_station(name: "x" * 90, latitude: 0, longitude: 0, tzfile: "UTC", amplitudes: [1.0])
        err = assert_raises(ArgumentError) { w.to_bytes }
        assert_match(/name is 90 bytes; libtcd allows 89/, err.message)
    end

    def test_rejects_characters_outside_latin1
        w = small_writer.add_station(name: "Tōkyō", latitude: 0, longitude: 0, tzfile: "UTC", amplitudes: [1.0])
        assert_raises(ArgumentError) { w.to_bytes }
    end

    def test_rejects_value_that_does_not_fit_its_field
        w = small_writer.add_station(name: "A", latitude: 0, longitude: 0, tzfile: "UTC", amplitudes: [60.0])
        assert_match(/amplitude value .* does not fit 19 unsigned bits/, assert_raises(ArgumentError) { w.to_bytes }.message)
    end

    def test_rejects_reference_index_outside_the_file
        w = small_writer.add_station(name: "S", latitude: 0, longitude: 0, tzfile: "UTC", record_type: 2,
                                     reference_station: 3)
        assert_raises(ArgumentError) { w.to_bytes }
    end
end
