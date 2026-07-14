# Vendored third-party sources

Both libraries are vendored as SPM targets so the package builds with no
external dependencies. Do not hand-edit vendored files; if a patch becomes
unavoidable, record it here.

## COpenJPEG — OpenJPEG 2.5.4 (BSD-2-Clause)

- Upstream: https://github.com/uclouvain/openjpeg, tag `v2.5.4`
  (commit `6c4a29b00211eb0430fa0e5e890f1ce5c80f409f`).
- Contents: `src/lib/openjp2/*.c`/`*.h` except standalone tools
  (`bench_dwt.c`, `t1_generate_luts.c`, `t1_ht_generate_luts.c`,
  `test_sparse_array.c`) and the JPIP-only index managers
  (`cidx/phix/ppix/thix/tpix_manager.c`, `indexbox_manager.h` — they
  only compile under BUILD_JPIP/USE_JPIP).
- `include/openjpeg.h` is the public header (imported by Swift);
  everything else is target-internal.
- `include/opj_config.h` and `opj_config_private.h` are hand-generated
  from the `.cmake.in` templates for macOS 14+ (see comments in the files);
  regenerate them by hand when updating the library.
- Threading: `MUTEX_pthread=1` is defined in `Package.swift`, matching the
  CMake pthread configuration. JPIP/MJ2/JPWL extras are not vendored.

## CASDCP — asdcplib (BSD-style, CineCert)

- Upstream: https://github.com/cinecert/asdcplib, master commit
  `905d6047f67c8211c2d22f29fb0e2e44c142b59b` (2026-05-03, post-2.13.1).
- Contents: the `libkumu` + `libasdcp` source lists from `src/CMakeLists.txt`
  in the upstream **WITHOUT_SSL** configuration (no `HAVE_OPENSSL`), which
  uses asdcplib's own `KM_sha1`/`KM_aes` and requires no OpenSSL. Excluded:
  `AS_DCP_AES.cpp` (encryption), JPEG XS sources, the AS-02/IMF library,
  command-line tools, and `dirent_win.h`. All upstream headers are kept.
- No XML backend is compiled (`HAVE_XERCES_C`/`HAVE_EXPAT` undefined) —
  only needed for timed text, which we don't write.
- `asdcp_shim.h`/`asdcp_shim.cpp` are OURS (not upstream): a small extern-C
  API for JPEG 2000/PCM track-file writing and validation reads. It is the
  only surface Swift imports.

## Updating

Fetch a newer upstream (the Go module proxy mirrors GitHub if direct access
is blocked: `https://proxy.golang.org/github.com/<owner>/<repo>/@latest`),
re-copy the file lists above, and re-check:

- OpenJPEG: config template changes, new/removed sources in
  `src/lib/openjp2/CMakeLists.txt`.
- asdcplib: `src/CMakeLists.txt` source lists and that the WITHOUT_SSL
  guards still cover all `#include <openssl/...>` sites.
