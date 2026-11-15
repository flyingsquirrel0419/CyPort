/* cyport-steam: the store log (shim/StoresCore.swift's storeLog) on stderr with CYPORT_VERBOSE=1.
   In the app this is the shim's macshim.log writer (shim/MacShimC.c). Never gets tokens or passwords. */
#include <stdio.h>
#include <stdlib.h>

void MacShimLogC(const char *what, const char *detail) {
    static int verbose = -1;
    if (verbose < 0) { const char *v = getenv("CYPORT_VERBOSE"); verbose = v && *v && *v != '0'; }
    if (verbose) fprintf(stderr, "[%s] %s\n", what, detail);
}
