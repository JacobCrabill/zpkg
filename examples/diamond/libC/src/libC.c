#include "libC.h"
#include "libA.h"
int c_double(int x)  { return a_add(x, x); }
int c_negate(int x)  { return a_sub(0, x); }
