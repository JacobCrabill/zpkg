#include "libE.h"
#include "libC.h"
#include "libD.h"
int e_transform(int x, int factor, int bits) {
    int doubled  = c_double(x);
    int scaled   = d_scale(doubled, factor);
    return d_low_bits(scaled, bits);
}
