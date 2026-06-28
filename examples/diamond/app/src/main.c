#include <stdio.h>
#include "libE.h"
int main(void) {
    int result = e_transform(3, 4, 8);
    printf("e_transform(3, 4, 8) = %d\n", result);
    return 0;
}
