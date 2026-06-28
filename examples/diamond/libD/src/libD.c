#include "libD.h"
#include "libA.h"
#include "libB.h"
/* d_scale: multiply x by factor using repeated addition via libA */
int d_scale(int x, int factor) {
    int result = 0;
    for (int i = 0; i < factor; i++) result = a_add(result, x);
    return result;
}
/* d_low_bits: shift then mask via libB */
int d_low_bits(int x, int n) { return b_mask(b_shift_left(x, 0), n); }
