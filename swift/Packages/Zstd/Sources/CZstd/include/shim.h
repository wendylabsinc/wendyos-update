// Umbrella header for the (now vendored, compiled-in) zstd library plus
// the system zlib. Only the streaming APIs declared here are used by the
// Zstd Swift target (ZSTD_*Stream* from zstd.h, inflate/deflate from
// zlib.h).
//
// zstd.h is vendored (see VENDORED.md) so the static-musl cross build
// doesn't need zstd.h in the SDK sysroot; zlib.h stays a system header
// since the musl Static Linux SDK does ship zlib.h + a static libz.
#ifndef CZSTD_SHIM_H
#define CZSTD_SHIM_H

#include "zstd.h"
#include <zlib.h>

#endif /* CZSTD_SHIM_H */
