/* tcd_fulldump: print everything libtcd reads from a TCD file, in a fixed text form.
 *
 *   tcd_fulldump FILE.tcd
 *
 * Sections: header (public fields), lookup tables, constituents (speed, every year's
 * equilibrium and node factor), then every station record with every field.
 * Floats are printed at the precision the file stores them, so two files that hold the
 * same values print the same bytes.
 *
 *   cc -I<libtcd>/include tcd_fulldump.c <libtcd>/lib/libtcd.a -lm -o tcd_fulldump
 *   TCD_LIBTCD_DUMP=./tcd_fulldump rake test
 */
#include <stdio.h>
#include <stdlib.h>
#include "tcd.h"

static void pstr (const char *k, const char *v) { printf ("%s=%s\n", k, v ? v : "(null)"); }

int main (int argc, char **argv) {
    if (argc != 2) { fprintf (stderr, "usage: %s FILE.tcd\n", argv[0]); return 2; }
    if (!open_tide_db (argv[1])) { fprintf (stderr, "%s: libtcd could not open it\n", argv[1]); return 1; }
    DB_HEADER_PUBLIC db = get_tide_db_header ();
    NV_U_INT32 i, y;
    printf ("version=%s\nmajor_rev=%u\nminor_rev=%u\nlast_modified=%s\n", db.version, db.major_rev, db.minor_rev, db.last_modified);
    printf ("number_of_records=%u\nstart_year=%d\nnumber_of_years=%u\nconstituents=%u\n", db.number_of_records, db.start_year, db.number_of_years, db.constituents);
    printf ("level_unit_types=%u\ndir_unit_types=%u\nrestriction_types=%u\ndatum_types=%u\ncountries=%u\ntzfiles=%u\nlegaleses=%u\n",
            db.level_unit_types, db.dir_unit_types, db.restriction_types, db.datum_types, db.countries, db.tzfiles, db.legaleses);
    for (i = 0; i < db.level_unit_types; ++i) printf ("level_unit[%u]=%s\n", i, get_level_units (i));
    for (i = 0; i < db.dir_unit_types; ++i) printf ("dir_unit[%u]=%s\n", i, get_dir_units (i));
    for (i = 0; i < db.restriction_types; ++i) printf ("restriction[%u]=%s\n", i, get_restriction (i));
    for (i = 0; i < db.datum_types; ++i) printf ("datum[%u]=%s\n", i, get_datum (i));
    for (i = 0; i < db.countries; ++i) printf ("country[%u]=%s\n", i, get_country (i));
    for (i = 0; i < db.tzfiles; ++i) printf ("tzfile[%u]=%s\n", i, get_tzfile (i));
    for (i = 0; i < db.legaleses; ++i) printf ("legalese[%u]=%s\n", i, get_legalese (i));
    for (i = 0; i < db.constituents; ++i) {
        printf ("constituent[%u]=%s speed=%.7f\n eq=", i, get_constituent (i), get_speed (i));
        for (y = 0; y < db.number_of_years; ++y) printf (y ? ",%.2f" : "%.2f", get_equilibrium (i, y));
        printf ("\n nf=");
        for (y = 0; y < db.number_of_years; ++y) printf (y ? ",%.4f" : "%.4f", get_node_factor (i, y));
        printf ("\n");
    }
    for (i = 0; i < db.number_of_records; ++i) {
        TIDE_RECORD r;
        if (read_tide_record (i, &r) != (NV_INT32) i) { fprintf (stderr, "record %u unreadable\n", i); return 1; }
        printf ("record[%u] size=%u type=%u lat=%.5f lon=%.5f ref=%d tz=%d:%s\n", i, r.header.record_size, r.header.record_type,
                r.header.latitude, r.header.longitude, r.header.reference_station, r.header.tzfile, get_tzfile (r.header.tzfile));
        pstr (" name", r.header.name);
        printf (" country=%d:%s\n", r.country, get_country (r.country));
        pstr (" source", r.source);
        printf (" restriction=%u:%s\n", r.restriction, get_restriction (r.restriction));
        pstr (" comments", r.comments);
        pstr (" notes", r.notes);
        printf (" legalese=%u:%s\n", r.legalese, get_legalese (r.legalese));
        pstr (" station_id_context", r.station_id_context);
        pstr (" station_id", r.station_id);
        printf (" date_imported=%u\n", r.date_imported);
        pstr (" xfields", r.xfields);
        printf (" direction_units=%u:%s min_direction=%d max_direction=%d level_units=%u:%s\n", r.direction_units,
                get_dir_units (r.direction_units), r.min_direction, r.max_direction, r.level_units, get_level_units (r.level_units));
        if (r.header.record_type == REFERENCE_STATION) {
            printf (" datum_offset=%.4f datum=%d:%s zone_offset=%d expiration_date=%u months_on_station=%u last_date_on_station=%u confidence=%u\n",
                    r.datum_offset, r.datum, get_datum (r.datum), r.zone_offset, r.expiration_date, r.months_on_station,
                    r.last_date_on_station, r.confidence);
            for (y = 0; y < db.constituents; ++y)
                if (r.amplitude[y] != 0.0 || r.epoch[y] != 0.0)
                    printf (" c[%u]=%.4f,%.2f\n", y, r.amplitude[y], r.epoch[y]);
        } else {
            printf (" min_time_add=%d min_level_add=%.3f min_level_multiply=%.3f max_time_add=%d max_level_add=%.3f max_level_multiply=%.3f flood_begins=%d ebb_begins=%d\n",
                    r.min_time_add, r.min_level_add, r.min_level_multiply, r.max_time_add, r.max_level_add, r.max_level_multiply,
                    r.flood_begins, r.ebb_begins);
        }
    }
    close_tide_db ();
    return ferror (stdout) ? 1 : 0;
}
