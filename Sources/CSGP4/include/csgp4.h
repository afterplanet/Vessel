#ifndef CSGP4_H
#define CSGP4_H
#ifdef __cplusplus
extern "C" {
#endif

typedef struct csgp4_sat csgp4_sat;

/// Build a propagator from mean elements (OMM fields, units as published:
/// degrees, rev/day, rev/day^2, rev/day^3, 1/earth radii). `jd_epoch` is the Julian date.
csgp4_sat *csgp4_create(double jd_epoch, double bstar, double ndot, double nddot,
                        double ecc, double argp_deg, double incl_deg, double mo_deg,
                        double n_revday, double raan_deg);
void csgp4_free(csgp4_sat *s);
/// TEME position (km) and velocity (km/s) at Julian date `jd`. Returns 1 on success.
int csgp4_propagate(csgp4_sat *s, double jd, double r[3], double v[3]);
double csgp4_gmst(double jd);

#ifdef __cplusplus
}
#endif
#endif
