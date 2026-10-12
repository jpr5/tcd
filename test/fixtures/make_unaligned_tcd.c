/* Builds test/fixtures/unaligned-11.tcd with libtcd 2.2.7 (public domain):
 * 11 constituents (not a multiple of 8) over 3 years, one reference and one
 * subordinate station. All values are synthetic.
 *
 *   cc -I<libtcd>/include make_unaligned_tcd.c <libtcd>/lib/libtcd.a -lm -o make_unaligned_tcd
 *   ./make_unaligned_tcd unaligned-11.tcd
 */
#include <stdio.h>
#include <string.h>
#include "tcd.h"

#define NC 11
#define NY 3

int main (int argc, char **argv) {
    const char *names[NC] = {"M2", "S2", "N2", "K1", "O1", "P1", "K2", "Q1", "M4", "MS4", "SA"};
    double speeds[NC] = {28.9841042, 30.0, 28.4397295, 15.0410686, 13.9430356, 14.9589314,
                         30.0821373, 13.3986609, 57.9682084, 58.9841042, 0.0410686};
    float eqs[NC][NY], nfs[NC][NY];
    const float *eqp[NC], *nfp[NC];
    DB_HEADER_PUBLIC db;
    TIDE_RECORD r;
    int c, y;
    if (argc != 2) return 2;
    for (c = 0; c < NC; ++c) {
        for (y = 0; y < NY; ++y) {
            eqs[c][y] = (float) ((c * 37 + y * 101) % 300) + 0.25f * y;
            nfs[c][y] = 0.9f + 0.0125f * c + 0.01f * y;
        }
        eqp[c] = eqs[c];
        nfp[c] = nfs[c];
    }
    if (!create_tide_db (argv[1], NC, names, speeds, 2020, NY, eqp, nfp)) return 1;
    db = get_tide_db_header ();

    memset (&r, 0, sizeof r);
    r.header.record_type = REFERENCE_STATION;
    r.header.latitude = 41.5;
    r.header.longitude = -70.67;
    r.header.reference_station = -1;
    r.header.tzfile = find_tzfile (":America/New_York");
    strcpy (r.header.name, "Synthetic Reference");
    r.country = find_country ("United States");
    strcpy (r.source, "tcd gem test fixture");
    r.restriction = 0;
    r.legalese = 0;
    r.direction_units = 1;
    r.min_direction = r.max_direction = 361;
    r.level_units = find_level_units ("meters");
    r.datum_offset = 1.2345f;
    r.datum = find_datum ("Mean Lower Low Water");
    r.zone_offset = -500;
    for (c = 0; c < NC; ++c) {
        r.amplitude[c] = c == 4 ? 0.0f : 0.05f + 0.1f * c;
        r.epoch[c] = c == 4 ? 0.0f : 10.0f * c + 0.5f;
    }
    if (!add_tide_record (&r, &db)) return 1;

    memset (&r, 0, sizeof r);
    r.header.record_type = SUBORDINATE_STATION;
    r.header.latitude = 41.6;
    r.header.longitude = -70.6;
    r.header.reference_station = 0;
    r.header.tzfile = find_tzfile (":America/New_York");
    strcpy (r.header.name, "Synthetic Subordinate");
    r.country = find_country ("United States");
    r.direction_units = 1;
    r.min_direction = r.max_direction = 361;
    r.level_units = find_level_units ("meters");
    r.min_time_add = 112;
    r.max_time_add = -45;
    r.min_level_add = 0.1f;
    r.max_level_add = -0.2f;
    r.min_level_multiply = 0.9f;
    r.max_level_multiply = 1.1f;
    r.flood_begins = r.ebb_begins = NULLSLACKOFFSET;
    if (!add_tide_record (&r, &db)) return 1;
    close_tide_db ();
    return 0;
}
