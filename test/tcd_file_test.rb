# frozen_string_literal: true

require_relative "test_helper"

# Integration tests that require the actual TCD file
class TCDFileTest < Minitest::Test
    def test_opens_and_closes_file
        reader = TCD.open(TCD_TEST_FILE)
        assert_instance_of TCD::Reader, reader
        reader.close
    end

    def test_block_form_closes_file
        result = TCD.open(TCD_TEST_FILE) do |db|
            db.station_count
        end
        assert result > 0
    end

    def test_reads_header
        TCD.open(TCD_TEST_FILE) do |db|
            assert_kind_of String, db.version
            assert_kind_of String, db.last_modified
            assert db.station_count > 0
            assert db.constituent_count > 0
        end
    end

    def test_reads_year_range
        TCD.open(TCD_TEST_FILE) do |db|
            year_range = db.year_range
            assert_kind_of Range, year_range
            assert year_range.first <= 2000
            assert year_range.last >= 2050
        end
    end

    def test_reads_lookup_tables
        TCD.open(TCD_TEST_FILE) do |db|
            tables = db.lookup_tables

            # Level units
            assert tables.level_units.size > 0
            assert tables.level_units.include?("feet") || tables.level_units.include?("meters")

            # Direction units
            assert tables.direction_units.size > 0

            # Timezones
            assert tables.timezones.size > 100
            assert tables.timezones.any? { |tz| tz.include?("America") }

            # Countries
            assert tables.countries.size > 100
            assert tables.countries.include?("USA") || tables.countries.include?("United States")

            # Datums
            assert tables.datums.size > 10
            assert tables.datums.any? { |d| d.include?("Mean") }

            # Constituents
            assert tables.constituents.size > 30
            assert tables.constituents.include?("M2") || tables.constituents.include?("K1")
        end
    end

    def test_reads_constituents
        TCD.open(TCD_TEST_FILE) do |db|
            constituents = db.constituents

            assert constituents.size > 30

            # Find M2 (principal lunar semidiurnal)
            m2 = db.constituent("M2")
            if m2
                assert_kind_of TCD::Constituent, m2
                assert_in_delta 28.984, m2.speed, 0.01
                assert_kind_of Array, m2.equilibrium
                assert_kind_of Array, m2.node_factors
                assert m2.equilibrium.size == db.header.number_of_years
                assert m2.node_factors.size == db.header.number_of_years
            end

            # All speeds should be positive and reasonable (0-180 degrees/hour)
            constituents.each do |c|
                assert c.speed >= 0, "Speed should be >= 0 for #{c.name}"
                assert c.speed <= 180, "Speed should be <= 180 for #{c.name}"
            end
        end
    end

    def test_reads_stations
        TCD.open(TCD_TEST_FILE) do |db|
            stations = db.stations

            assert stations.size > 1000
            assert stations.size == db.station_count

            # Check that we have both reference and subordinate stations
            ref_count = stations.count(&:reference?)
            sub_count = stations.count(&:subordinate?)
            assert ref_count > 0
            assert sub_count > 0
            assert_equal stations.size, ref_count + sub_count
        end
    end

    def test_reference_station_fields
        TCD.open(TCD_TEST_FILE) do |db|
            ref_station = db.reference_stations.first
            assert ref_station.reference?
            refute ref_station.subordinate?

            # Required fields
            assert_kind_of String, ref_station.name
            assert ref_station.name.length > 0
            assert_in_delta ref_station.latitude, ref_station.latitude, 90
            assert_in_delta ref_station.longitude, ref_station.longitude, 180
            assert_kind_of String, ref_station.tzfile
            assert_kind_of String, ref_station.country

            # Reference-specific fields
            assert_kind_of String, ref_station.datum if ref_station.datum
            assert_kind_of Array, ref_station.amplitudes
            assert_kind_of Array, ref_station.epochs
            assert ref_station.amplitudes.size == db.constituent_count
            assert ref_station.epochs.size == db.constituent_count

            # Active constituents count should be reasonable
            assert ref_station.active_constituents > 0
            assert ref_station.active_constituents <= db.constituent_count
        end
    end

    def test_subordinate_station_fields
        TCD.open(TCD_TEST_FILE) do |db|
            sub_station = db.subordinate_stations.first
            refute sub_station.reference?
            assert sub_station.subordinate?

            # Required fields
            assert_kind_of String, sub_station.name
            assert sub_station.name.length > 0
            assert_in_delta sub_station.latitude, sub_station.latitude, 90
            assert_in_delta sub_station.longitude, sub_station.longitude, 180

            # Subordinate-specific fields
            assert sub_station.reference_station >= 0
            # Time offsets are integers (minutes)
            assert_kind_of Integer, sub_station.min_time_add if sub_station.min_time_add
            assert_kind_of Integer, sub_station.max_time_add if sub_station.max_time_add
            # Level multiply should be around 1.0
            if sub_station.min_level_multiply
                assert sub_station.min_level_multiply > 0
                assert sub_station.min_level_multiply < 10
            end
        end
    end

    def test_find_stations
        TCD.open(TCD_TEST_FILE) do |db|
            results = db.find_stations("San Francisco")
            assert results.size > 0
            assert results.all? { |s| s.name.downcase.include?("san francisco") }
        end
    end

    def test_station_by_name
        TCD.open(TCD_TEST_FILE) do |db|
            # Find a known station
            station = db.find_stations("San Francisco").first
            if station
                exact = db.station_by_name(station.name)
                assert_equal station.name, exact.name
            end
        end
    end

    def test_stats
        TCD.open(TCD_TEST_FILE) do |db|
            stats = db.stats
            assert_kind_of Hash, stats
            assert_equal db.station_count, stats[:total_stations]
            assert_equal db.constituent_count, stats[:constituents]
            assert stats[:reference_stations] > 0
            assert stats[:subordinate_stations] > 0
            assert_equal stats[:total_stations],
                         stats[:reference_stations] + stats[:subordinate_stations]
        end
    end

    def test_coordinate_ranges
        TCD.open(TCD_TEST_FILE) do |db|
            db.stations.each_with_index do |s, i|
                # Skip first few to speed up test, then sample randomly
                next if i > 10 && i % 100 != 0

                assert s.latitude >= -90 && s.latitude <= 90,
                       "Latitude out of range for station #{s.name}: #{s.latitude}"
                assert s.longitude >= -180 && s.longitude <= 180,
                       "Longitude out of range for station #{s.name}: #{s.longitude}"
            end
        end
    end

    def test_each_station_enumerable
        TCD.open(TCD_TEST_FILE) do |db|
            # Test that each_station returns an enumerator
            enum = db.each_station
            assert_kind_of Enumerator, enum

            # Test that we can iterate
            first_five = db.each_station.take(5)
            assert_equal 5, first_five.size
            assert first_five.all? { |s| s.is_a?(TCD::Station) }
        end
    end

    def test_nearest_station
        TCD.open(TCD_TEST_FILE) do |db|
            # Find nearest station to San Francisco coordinates
            nearest = db.nearest_station(37.8, -122.4)
            assert_kind_of TCD::Station, nearest

            # Should be somewhere in the SF Bay Area
            assert nearest.latitude > 37 && nearest.latitude < 39
            assert nearest.longitude > -123 && nearest.longitude < -121
        end
    end

    def test_nearest_station_with_type_filter
        TCD.open(TCD_TEST_FILE) do |db|
            # Find nearest reference station
            nearest_ref = db.nearest_station(37.8, -122.4, type: :reference)
            assert nearest_ref.reference?

            # Find nearest subordinate station
            nearest_sub = db.nearest_station(37.8, -122.4, type: :subordinate)
            assert nearest_sub.subordinate?
        end
    end

    def test_stations_near
        TCD.open(TCD_TEST_FILE) do |db|
            # Find stations within ~50km of San Francisco (0.5 degrees)
            nearby = db.stations_near(37.8, -122.4, radius: 0.5)

            assert nearby.size > 0
            assert nearby.all? do |s|
                dlat = (37.8 - s.latitude).abs
                dlon = (-122.4 - s.longitude).abs
                dlat <= 0.5 && dlon <= 0.5
            end

            # Should be sorted by distance
            distances = nearby.map do |s|
                dlat = 37.8 - s.latitude
                dlon = -122.4 - s.longitude
                dlat * dlat + dlon * dlon
            end
            assert_equal distances.sort, distances
        end
    end

    def test_simple_and_current_station_types
        TCD.open(TCD_TEST_FILE) do |db|
            # Reference stations are always tide stations
            ref = db.reference_stations.first
            assert ref.tide?
            refute ref.current?
            refute ref.simple?

            # Find a simple subordinate (tide station)
            simple_sub = db.subordinate_stations.find(&:simple?)
            if simple_sub
                assert simple_sub.simple?
                assert simple_sub.tide?
                refute simple_sub.current?
            end

            # Find a non-simple subordinate with different high/low corrections (tide station)
            # These are tide stations that happen to have asymmetric corrections
            tide_with_corrections = db.subordinate_stations.find { |s|
                !s.simple? && s.flood_begins.nil? && s.ebb_begins.nil?
            }
            if tide_with_corrections
                refute tide_with_corrections.simple?
                assert tide_with_corrections.tide?, "Station with asymmetric corrections but no current data should be tide station"
                refute tide_with_corrections.current?
            end

            # Find an actual current station (has flood/ebb or direction data)
            current_sub = db.subordinate_stations.find { |s|
                s.flood_begins || s.ebb_begins || s.min_direction || s.max_direction
            }
            if current_sub
                assert current_sub.current?, "Station with flood/ebb/direction data should be current station"
                refute current_sub.tide?
            end
        end
    end

    # Regression test for tide/current classification bug
    # Some subordinate stations have different high/low corrections but no current data
    # These should be classified as tide stations, not current stations
    def test_subordinate_tide_with_asymmetric_corrections
        TCD.open(TCD_TEST_FILE) do |db|
            # Find subordinate stations with different time/level corrections but no current data
            asymmetric_tides = db.subordinate_stations.select { |s|
                (s.max_time_add != s.min_time_add ||
                 s.max_level_multiply != s.min_level_multiply) &&
                s.flood_begins.nil? &&
                s.ebb_begins.nil? &&
                s.min_direction.nil? &&
                s.max_direction.nil?
            }

            skip "No asymmetric tide stations in test file" if asymmetric_tides.empty?

            sample = asymmetric_tides.first
            assert sample.tide?, "#{sample.name} should be tide station (no current indicators)"
            refute sample.current?, "#{sample.name} should not be current station"
            refute sample.simple?, "#{sample.name} should not be simple (has asymmetric corrections)"
        end
    end
end
