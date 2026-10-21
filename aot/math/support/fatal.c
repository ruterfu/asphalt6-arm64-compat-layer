/* Independent fatal diagnostic for impossible internal mathematical states. */
#include "as6_math_support.h"
_Noreturn void as6_math_fatal(const char *source, unsigned line) {
    (void)source;
    (void)line;
    abort();
}
