/**
 @file  enet_time.h
 @brief ENet time constants and macros

 Upstream calls this enet/time.h. It is renamed here because this vendoring
 flattened ENet's headers into one directory that is on the include path, so a
 file called time.h shadowed the system <time.h> for every angle-bracket
 include in the target — including unix.c's, which wants the real one for
 time(). That was survivable while clang treated the resulting implicit
 declaration as a warning, and stopped being survivable when it became an
 error: the package would not build from a clean checkout at all.
*/
#ifndef __ENET_TIME_H__
#define __ENET_TIME_H__

#define ENET_TIME_OVERFLOW 86400000

#define ENET_TIME_LESS(a, b) ((a) - (b) >= ENET_TIME_OVERFLOW)
#define ENET_TIME_GREATER(a, b) ((b) - (a) >= ENET_TIME_OVERFLOW)
#define ENET_TIME_LESS_EQUAL(a, b) (! ENET_TIME_GREATER (a, b))
#define ENET_TIME_GREATER_EQUAL(a, b) (! ENET_TIME_LESS (a, b))

#define ENET_TIME_DIFFERENCE(a, b) ((a) - (b) >= ENET_TIME_OVERFLOW ? (b) - (a) : (a) - (b))

#endif /* __ENET_TIME_H__ */

