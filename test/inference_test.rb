# frozen_string_literal: true

require_relative "test_helper"

class InferenceTest < Minitest::Test
    def test_infer_constituents_on_reference_station
        TCD.open(TCD_TEST_FILE) do |db|
            # Find a reference station with the required constituents
            station = db.reference_stations.find do |s|
                m2 = db.constituent("M2")
                s2 = db.constituent("S2")
                k1 = db.constituent("K1")
                o1 = db.constituent("O1")

                next false unless m2 && s2 && k1 && o1

                s.amplitudes[m2.index] > 0 &&
                    s.amplitudes[s2.index] > 0 &&
                    s.amplitudes[k1.index] > 0 &&
                    s.amplitudes[o1.index] > 0
            end

            skip "No suitable station found for inference test" unless station

            # Count constituents before inference
            before_count = station.active_constituents

            # Perform inference
            result = db.infer_constituents(station)

            # If there were missing constituents, inference should work
            # If all constituents already present, it may return true but no change
            assert result, "Inference should succeed when required constituents are present"

            # After inference, we should have at least as many constituents
            after_count = station.active_constituents
            assert after_count >= before_count, "Should not lose constituents"
        end
    end

    def test_infer_constituents_fails_on_subordinate
        TCD.open(TCD_TEST_FILE) do |db|
            station = db.subordinate_stations.first
            skip "No subordinate station found" unless station

            result = db.infer_constituents(station)
            refute result, "Inference should fail for subordinate stations"
        end
    end

    def test_infer_constituents_fails_without_required_constituents
        TCD.open(TCD_TEST_FILE) do |db|
            # Find a reference station missing one of the required constituents
            station = db.reference_stations.find do |s|
                m2 = db.constituent("M2")
                s2 = db.constituent("S2")
                k1 = db.constituent("K1")
                o1 = db.constituent("O1")

                next false unless m2 && s2 && k1 && o1

                # Looking for one that's missing at least one required constituent
                s.amplitudes[m2.index] == 0 ||
                    s.amplitudes[s2.index] == 0 ||
                    s.amplitudes[k1.index] == 0 ||
                    s.amplitudes[o1.index] == 0
            end

            skip "No station missing required constituents found" unless station

            result = db.infer_constituents(station)
            refute result, "Inference should fail when required constituents are missing"
        end
    end

    def test_inference_constants_exist
        assert_equal 10, TCD::Inference::INFERRED_SEMI_DIURNAL.size
        assert_equal 10, TCD::Inference::INFERRED_DIURNAL.size
        assert_equal 10, TCD::Inference::SEMI_DIURNAL_COEFF.size
        assert_equal 10, TCD::Inference::DIURNAL_COEFF.size

        assert TCD::Inference::INFERRED_SEMI_DIURNAL.include?("N2")
        assert TCD::Inference::INFERRED_SEMI_DIURNAL.include?("K2")
        assert TCD::Inference::INFERRED_DIURNAL.include?("P1")
        assert TCD::Inference::INFERRED_DIURNAL.include?("Q1")

        assert_in_delta 0.9085, TCD::Inference::M2_COEFF, 0.0001
        assert_in_delta 0.3771, TCD::Inference::O1_COEFF, 0.0001
    end

    def test_inferred_amplitudes_are_reasonable
        TCD.open(TCD_TEST_FILE) do |db|
            # Find a station that needs inference
            station = db.reference_stations.find do |s|
                m2 = db.constituent("M2")
                s2 = db.constituent("S2")
                k1 = db.constituent("K1")
                o1 = db.constituent("O1")
                n2 = db.constituent("N2")

                next false unless m2 && s2 && k1 && o1 && n2

                # Has required constituents but missing N2 (commonly inferred)
                s.amplitudes[m2.index] > 0 &&
                    s.amplitudes[s2.index] > 0 &&
                    s.amplitudes[k1.index] > 0 &&
                    s.amplitudes[o1.index] > 0 &&
                    s.amplitudes[n2.index] == 0
            end

            skip "No suitable station for amplitude test" unless station

            n2 = db.constituent("N2")
            m2 = db.constituent("M2")
            original_m2_amp = station.amplitudes[m2.index]

            db.infer_constituents(station)

            # N2 is typically about 20% of M2 (coefficient 0.1759 / 0.9085 ≈ 0.194)
            n2_amp = station.amplitudes[n2.index]
            assert n2_amp > 0, "N2 should be inferred"

            # Verify the ratio is reasonable (N2 should be roughly 15-25% of M2)
            ratio = n2_amp / original_m2_amp
            assert ratio > 0.1, "N2/M2 ratio should be > 0.1, got #{ratio}"
            assert ratio < 0.3, "N2/M2 ratio should be < 0.3, got #{ratio}"
        end
    end
end
