# frozen_string_literal: true

module TCD
    # Computes inferred constituents when M2, S2, K1, and O1 are given.
    # This fills remaining unfilled constituents based on article 230 of
    # "Manual of Harmonic Analysis and Prediction of Tides",
    # Paul Schureman, C & GS special publication no. 98, October 1971.
    #
    # This is useful for stations with short observation periods that only
    # have a few major constituents developed. The inferred constituents
    # can improve tide predictions.
    module Inference
        # Semi-diurnal constituents that can be inferred from M2 and S2
        INFERRED_SEMI_DIURNAL = %w[N2 NU2 MU2 2N2 LDA2 T2 R2 L2 K2 KJ2].freeze

        # Coefficients for semi-diurnal inference (relative to M2)
        SEMI_DIURNAL_COEFF = [
            0.1759,  # N2
            0.0341,  # NU2
            0.0219,  # MU2
            0.0235,  # 2N2
            0.0066,  # LDA2
            0.0248,  # T2
            0.0035,  # R2
            0.0251,  # L2
            0.1151,  # K2
            0.0064   # KJ2
        ].freeze

        # Diurnal constituents that can be inferred from K1 and O1
        INFERRED_DIURNAL = %w[OO1 M1 J1 RHO1 Q1 2Q1 P1 PI1 PHI1 PSI1].freeze

        # Coefficients for diurnal inference (relative to O1)
        DIURNAL_COEFF = [
            0.0163,  # OO1
            0.0209,  # M1
            0.0297,  # J1
            0.0142,  # RHO1
            0.0730,  # Q1
            0.0097,  # 2Q1
            0.1755,  # P1
            0.0103,  # PI1
            0.0076,  # PHI1
            0.0042   # PSI1
        ].freeze

        # Reference coefficients for M2 and O1
        M2_COEFF = 0.9085
        O1_COEFF = 0.3771

        # Infer missing constituents for a reference station.
        #
        # Requires the station to have non-zero values for M2, S2, K1, and O1.
        # Modifies the station's amplitudes and epochs arrays in place.
        #
        # @param station [Station] A reference station with amplitudes/epochs arrays
        # @param constituent_data [ConstituentData] The constituent data from the reader
        # @return [Boolean] true if inference was performed, false if not enough data
        def self.infer_constituents(station, constituent_data)
            return false unless station.reference?
            return false unless station.amplitudes && station.epochs

            # Find the required constituents
            m2 = constituent_data.find("M2")
            s2 = constituent_data.find("S2")
            k1 = constituent_data.find("K1")
            o1 = constituent_data.find("O1")

            return false unless m2 && s2 && k1 && o1

            m2_idx = m2.index
            s2_idx = s2.index
            k1_idx = k1.index
            o1_idx = o1.index

            # Check that all four required constituents have non-zero values
            return false if station.amplitudes[m2_idx] == 0.0
            return false if station.amplitudes[s2_idx] == 0.0
            return false if station.amplitudes[k1_idx] == 0.0
            return false if station.amplitudes[o1_idx] == 0.0

            # Get the epochs, handling wrap-around
            epoch_m2 = station.epochs[m2_idx]
            epoch_s2 = station.epochs[s2_idx]
            epoch_k1 = station.epochs[k1_idx]
            epoch_o1 = station.epochs[o1_idx]

            # Build lookup from constituent name to index
            constituent_lookup = {}
            constituent_data.each_with_index do |c, idx|
                constituent_lookup[c.name] = idx
            end

            # Infer semi-diurnal constituents
            INFERRED_SEMI_DIURNAL.each_with_index do |name, j|
                idx = constituent_lookup[name]
                next unless idx
                next unless station.amplitudes[idx] == 0.0 && station.epochs[idx] == 0.0

                constituent = constituent_data[idx]
                next unless constituent

                # Compute amplitude
                station.amplitudes[idx] = (SEMI_DIURNAL_COEFF[j] / M2_COEFF) *
                                          station.amplitudes[m2_idx]

                # Compute epoch with wrap-around handling
                e_m2 = epoch_m2
                e_s2 = epoch_s2
                if (e_s2 - e_m2).abs > 180.0
                    if e_s2 < e_m2
                        e_s2 += 360.0
                    else
                        e_m2 += 360.0
                    end
                end

                speed_diff_ratio = (constituent.speed - m2.speed) / (s2.speed - m2.speed)
                station.epochs[idx] = e_m2 + speed_diff_ratio * (e_s2 - e_m2)
            end

            # Infer diurnal constituents
            INFERRED_DIURNAL.each_with_index do |name, j|
                idx = constituent_lookup[name]
                next unless idx
                next unless station.amplitudes[idx] == 0.0 && station.epochs[idx] == 0.0

                constituent = constituent_data[idx]
                next unless constituent

                # Compute amplitude
                station.amplitudes[idx] = (DIURNAL_COEFF[j] / O1_COEFF) *
                                          station.amplitudes[o1_idx]

                # Compute epoch with wrap-around handling
                e_k1 = epoch_k1
                e_o1 = epoch_o1
                if (e_k1 - e_o1).abs > 180.0
                    if e_k1 < e_o1
                        e_k1 += 360.0
                    else
                        e_o1 += 360.0
                    end
                end

                speed_diff_ratio = (constituent.speed - o1.speed) / (k1.speed - o1.speed)
                station.epochs[idx] = e_o1 + speed_diff_ratio * (e_k1 - e_o1)
            end

            true
        end
    end
end
