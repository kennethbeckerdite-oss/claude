/* Hand-generated from opj_config_private.h.cmake.in for the vendored SPM
   build targeting macOS 14+ (see TranscodeKit/VENDORED.md). */

#define OPJ_PACKAGE_VERSION "2.5.4"

#define OPJ_HAVE_FSEEKO

/* macOS: no <malloc.h>; posix_memalign is always available. */
#define OPJ_HAVE_POSIX_MEMALIGN

#if !defined(_POSIX_C_SOURCE)
#if defined(OPJ_HAVE_FSEEKO) || defined(OPJ_HAVE_POSIX_MEMALIGN)
/* Get declarations of fseeko, ftello, posix_memalign. */
#define _POSIX_C_SOURCE 200112L
#endif
#endif

/* Byte order: Apple compilers define __BIG_ENDIAN__/__LITTLE_ENDIAN__. */
#if !defined(__APPLE__)
/* little-endian assumed */
#elif defined(__BIG_ENDIAN__)
# define OPJ_BIG_ENDIAN
#endif
