#include "libB.h"
int b_shift_left(int x, int n) { return x << n; }
int b_mask(int x, int bits) { return x & ((1 << bits) - 1); }
