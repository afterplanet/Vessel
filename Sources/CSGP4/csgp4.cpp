#include "include/csgp4.h"
#include "SGP4.h"
#include <cmath>
#include <new>

struct csgp4_sat { elsetrec rec; };

static const double DEG = M_PI / 180.0;
static const double XPDOTP = 1440.0 / (2.0 * M_PI);

extern "C" csgp4_sat *csgp4_create(double jd_epoch, double bstar, double ndot, double nddot,
                                   double ecc, double argp, double incl, double mo,
                                   double n, double raan) {
    csgp4_sat *s = new (std::nothrow) csgp4_sat();
    if (!s) return nullptr;
    double whole = std::floor(jd_epoch - 0.5) + 0.5;
    s->rec.jdsatepoch = whole;
    s->rec.jdsatepochF = jd_epoch - whole;
    const char satn[9] = "00000";
    bool ok = SGP4Funcs::sgp4init(wgs72, 'i', satn, jd_epoch - 2433281.5, bstar,
                                  ndot / (XPDOTP * 1440.0), nddot / (XPDOTP * 1440.0 * 1440.0),
                                  ecc, argp * DEG, incl * DEG, mo * DEG, n / XPDOTP, raan * DEG, s->rec);
    if (!ok || s->rec.error != 0) { delete s; return nullptr; }
    return s;
}

extern "C" void csgp4_free(csgp4_sat *s) { delete s; }

extern "C" int csgp4_propagate(csgp4_sat *s, double jd, double r[3], double v[3]) {
    double tsince = (jd - s->rec.jdsatepoch - s->rec.jdsatepochF) * 1440.0;
    return SGP4Funcs::sgp4(s->rec, tsince, r, v) ? 1 : 0;
}

extern "C" double csgp4_gmst(double jd) { return SGP4Funcs::gstime_SGP4(jd); }
