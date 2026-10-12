# frozen_string_literal: true

require_relative "test_helper"

# test/fixtures/unaligned-11.tcd was written by libtcd 2.2.7 (make_unaligned_tcd.c).
# It has 11 constituents, so its speed table (11 x 30 bits) and its equilibrium
# table (33 x 15 bits) end part-way through a byte. libtcd starts each table on a
# byte boundary; the reader must do the same.
# Expected values are libtcd's own reading of the file.
class UnalignedTCDTest < Minitest::Test
    FIXTURE = File.expand_path("fixtures/unaligned-11.tcd", __dir__)

    def setup
        @db = TCD.open(FIXTURE)
    end

    def teardown
        @db.close
    end

    def test_fixture_tables_are_not_byte_aligned
        assert_equal 11, @db.constituent_count
        refute_equal 0, (@db.constituent_count * @db.header.speed_bits) % 8
    end

    def test_speeds
        assert_in_delta 28.9841042, @db.constituent("M2").speed, 1e-7
        assert_in_delta 0.0410686, @db.constituent("SA").speed, 1e-7
    end

    def test_equilibrium_arguments_match_libtcd
        assert_equal [0.00, 101.25, 202.50], @db.constituent("M2").equilibrium.map { |v| v.round(2) }
        assert_equal [185.00, 286.25, 87.50], @db.constituent("P1").equilibrium.map { |v| v.round(2) }
        assert_equal [70.00, 171.25, 272.50], @db.constituent("SA").equilibrium.map { |v| v.round(2) }
    end

    def test_node_factors_match_libtcd
        assert_equal [0.9000, 0.9100, 0.9200], @db.constituent("M2").node_factors.map { |v| v.round(4) }
        assert_equal [0.9875, 0.9975, 1.0075], @db.constituent("Q1").node_factors.map { |v| v.round(4) }
        assert_equal [1.0250, 1.0350, 1.0450], @db.constituent("SA").node_factors.map { |v| v.round(4) }
    end

    def test_every_constituent_value
        @db.constituents.each_with_index do |c, i|
            assert_equal (0...3).map { |y| ((i * 37 + y * 101) % 300) + 0.25 * y }, c.equilibrium.map { |v| v.round(2) }, c.name
            assert_equal (0...3).map { |y| (0.9 + 0.0125 * i + 0.01 * y).round(4) }, c.node_factors.map { |v| v.round(4) }, c.name
        end
    end

    def test_stations
        ref, sub = @db.stations
        assert_equal "Synthetic Reference", ref.name
        assert_equal "America/New_York", ref.tzfile
        assert_in_delta 1.2345, ref.datum_offset, 1e-9
        assert_in_delta 1.05, ref.amplitudes[10], 1e-9
        assert_in_delta 100.5, ref.epochs[10], 1e-9
        assert_equal 0.0, ref.amplitudes[4]
        assert_equal "Synthetic Subordinate", sub.name
        assert_equal 0, sub.reference_station
        assert_equal 72, sub.min_time_add
        assert_in_delta 1.1, sub.max_level_multiply, 1e-9
    end
end
