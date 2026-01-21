# frozen_string_literal: true

require_relative "test_helper"

class HeaderTest < Minitest::Test
    def setup
        @sample_header = <<~HEADER
            [VERSION] = Test TCD Reader v1.0
            [LAST MODIFIED] = 2025-01-01 00:00 UTC
            [HEADER SIZE] = 4096
            [NUMBER OF RECORDS] = 100
            [CONSTITUENTS] = 37
            [START YEAR] = 1970
            [NUMBER OF YEARS] = 100
            [MAJOR REV] = 2
            [MINOR REV] = 2
            [END OF FILE] = 1000000
            [SPEED BITS] = 31
            [SPEED SCALE] = 10000000
            [SPEED OFFSET] = -410667
            [EQUILIBRIUM BITS] = 16
            [EQUILIBRIUM SCALE] = 100
            [NODE BITS] = 15
            [NODE SCALE] = 10000
            [AMPLITUDE BITS] = 19
            [AMPLITUDE SCALE] = 10000
            [EPOCH BITS] = 16
            [EPOCH SCALE] = 100
            [RECORD TYPE BITS] = 4
            [LATITUDE BITS] = 25
            [LATITUDE SCALE] = 100000
            [LONGITUDE BITS] = 26
            [LONGITUDE SCALE] = 100000
            [RECORD SIZE BITS] = 16
            [STATION BITS] = 18
            [DATUM OFFSET BITS] = 28
            [DATUM OFFSET SCALE] = 10000
            [DATE BITS] = 27
            [MONTHS ON STATION BITS] = 10
            [CONFIDENCE VALUE BITS] = 4
            [TIME BITS] = 13
            [LEVEL ADD BITS] = 17
            [LEVEL ADD SCALE] = 1000
            [LEVEL MULTIPLY BITS] = 16
            [LEVEL MULTIPLY SCALE] = 1000
            [DIRECTION BITS] = 9
            [LEVEL UNIT BITS] = 3
            [LEVEL UNIT TYPES] = 5
            [LEVEL UNIT SIZE] = 15
            [DIRECTION UNIT BITS] = 2
            [DIRECTION UNIT TYPES] = 3
            [DIRECTION UNIT SIZE] = 15
            [RESTRICTION BITS] = 4
            [RESTRICTION TYPES] = 3
            [RESTRICTION SIZE] = 30
            [DATUM BITS] = 7
            [DATUM TYPES] = 61
            [DATUM SIZE] = 70
            [LEGALESE BITS] = 4
            [LEGALESE TYPES] = 2
            [LEGALESE SIZE] = 70
            [CONSTITUENT BITS] = 8
            [CONSTITUENT SIZE] = 10
            [COUNTRY BITS] = 9
            [COUNTRIES] = 243
            [COUNTRY SIZE] = 50
            [TZFILE BITS] = 10
            [TZFILES] = 407
            [TZFILE SIZE] = 30
            [END OF ASCII HEADER DATA]
        HEADER
        @io = StringIO.new(@sample_header)
    end

    def test_parses_version
        header = TCD::Header.new(@io)
        assert_equal "Test TCD Reader v1.0", header.version
    end

    def test_parses_last_modified
        header = TCD::Header.new(@io)
        assert_equal "2025-01-01 00:00 UTC", header.last_modified
    end

    def test_parses_integer_values
        header = TCD::Header.new(@io)
        assert_equal 4096, header.header_size
        assert_equal 100, header.number_of_records
        assert_equal 37, header.constituents
        assert_equal 1970, header.start_year
        assert_equal 100, header.number_of_years
        assert_equal 2, header.major_rev
        assert_equal 2, header.minor_rev
        assert_equal 1_000_000, header.end_of_file
    end

    def test_parses_bit_field_parameters
        header = TCD::Header.new(@io)
        assert_equal 31, header.speed_bits
        assert_equal 10_000_000, header.speed_scale
        assert_equal(-410667, header.speed_offset)
        assert_equal 16, header.equilibrium_bits
        assert_equal 100, header.equilibrium_scale
        assert_equal 15, header.node_bits
        assert_equal 10_000, header.node_scale
    end

    def test_parses_lookup_table_parameters
        header = TCD::Header.new(@io)
        assert_equal 5, header.level_unit_types
        assert_equal 15, header.level_unit_size
        assert_equal 3, header.direction_unit_types
        assert_equal 15, header.direction_unit_size
        assert_equal 243, header.countries
        assert_equal 50, header.country_size
        assert_equal 407, header.tzfiles
        assert_equal 30, header.tzfile_size
    end

    def test_bracket_access
        header = TCD::Header.new(@io)
        assert_equal 4096, header[:header_size]
        assert_equal "Test TCD Reader v1.0", header[:version]
    end

    def test_key_exists
        header = TCD::Header.new(@io)
        assert header.key?(:header_size)
        assert header.key?(:version)
        refute header.key?(:nonexistent)
    end

    def test_missing_required_keys_raises_error
        bad_header = <<~HEADER
            [VERSION] = Test
            [END OF ASCII HEADER DATA]
        HEADER
        io = StringIO.new(bad_header)
        assert_raises(TCD::FormatError) { TCD::Header.new(io) }
    end

    def test_key_normalization
        header = TCD::Header.new(@io)
        # "HEADER SIZE" should become :header_size
        assert header.key?(:header_size)
        # "NUMBER OF RECORDS" should become :number_of_records
        assert header.key?(:number_of_records)
        # "LEVEL UNIT BITS" should become :level_unit_bits
        assert header.key?(:level_unit_bits)
    end
end
