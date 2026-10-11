// DyldInterpose.h - makes the guest believe it is the main executable.
#ifndef DYLDINTERPOSE_H
#define DYLDINTERPOSE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Set the path that _NSGetExecutablePath() and @executable_path resolve to.
 * Must be called BEFORE dlopen() of the guest so its dependencies resolve.
 * Returns 0 on success, -1 if the dyld-internal pointer could not be found
 * (the interposed _NSGetExecutablePath still answers with the guest path). */
int di_set_guest_executable_path(const char *guest_path);

/* Path currently reported to the guest (NULL before configuration). */
const char *di_guest_executable_path(void);

/* Rebind `symbol` inside every loaded image's GOT / lazy pointers to
 * `replacement` (fishhook-style). Returns number of slots rewritten. */
int di_rebind_symbol(const char *symbol, void *replacement, void **original);

/* Intercepts guest calls to exit() / _exit() to prevent terminating host app. */
void di_enable_exit_interposing(void (*on_exit_cb)(int status));

#ifdef __cplusplus
}
#endif
#endif
