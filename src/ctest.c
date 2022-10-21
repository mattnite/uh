#include <assert.h>
#include <stdbool.h>
#include <stdio.h>

#define FOO
#define MY_NUM (5)

int main() {
// logical operator precedence over conditional
#if defined(UNDEFINED) || MY_NUM > 2
    assert(true);
#else
    assert(false);
#endif

// logical operators can be nested inside comparisons
#if (defined(UNDEFINED) || MY_NUM) == 1
    assert(true);
#else
    assert(false);
#endif

// comparison operators have precedence over arithmetic
#if MY_NUM < 2 * 3
    assert(true);
#else
    assert(false);
#endif

// comparison operators can be nested inside aritmetic
#if (MY_NUM < 2) * 3 == 0
    assert(true);
#else
    assert(false);
#endif

// logical operators can be nested inside arithmetic
#if (MY_NUM && defined(FOO)) * 3 == 3
    assert(true);
#else
    assert(false);
#endif
}
