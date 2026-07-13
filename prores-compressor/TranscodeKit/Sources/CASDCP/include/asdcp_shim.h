/* asdcp_shim.h — minimal C API over asdcplib for DCPKit (Swift).
 *
 * This header is the only part of CASDCP that Swift imports. It covers
 * exactly what an unencrypted SMPTE 2K DCP needs: writing a JPEG 2000
 * picture track file, writing a PCM audio track file, and re-reading
 * both for post-export validation.
 *
 * All functions return 0 on success and a negative value on failure,
 * writing a human-readable message into err_buf when provided.
 */

#ifndef ASDCP_SHIM_H
#define ASDCP_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct asdcp_j2k_writer asdcp_j2k_writer;
typedef struct asdcp_pcm_writer asdcp_pcm_writer;

/* Identity stamped into MXF headers; asset_uuid becomes the track file's
 * asset UUID and must match the Id used for it in the CPL/PKL. */
typedef struct asdcp_writer_config {
    uint8_t     asset_uuid[16];
    const char *company_name;
    const char *product_name;
    const char *product_version;
} asdcp_writer_config;

/* --- JPEG 2000 picture track file (SMPTE, 24/1 edit rate) --- */

/* first_frame is a complete J2C codestream; its metadata (dimensions,
 * tiling, profile) populates the MXF picture descriptor. The frame is
 * NOT written — call asdcp_j2k_write_frame for every frame including
 * the first. */
asdcp_j2k_writer *asdcp_j2k_writer_open(const char *path,
                                        const asdcp_writer_config *config,
                                        const uint8_t *first_frame,
                                        size_t first_frame_len,
                                        uint32_t edit_rate_num,
                                        uint32_t edit_rate_den,
                                        char *err_buf, size_t err_buf_len);

int asdcp_j2k_write_frame(asdcp_j2k_writer *writer,
                          const uint8_t *frame, size_t frame_len,
                          char *err_buf, size_t err_buf_len);

/* Finalizes and frees the writer (even on failure). */
int asdcp_j2k_writer_finish(asdcp_j2k_writer *writer,
                            char *err_buf, size_t err_buf_len);

/* Aborts and frees the writer without finalizing (partial file remains). */
void asdcp_j2k_writer_abort(asdcp_j2k_writer *writer);

/* --- PCM audio track file (24-bit little-endian, interleaved) --- */

asdcp_pcm_writer *asdcp_pcm_writer_open(const char *path,
                                        const asdcp_writer_config *config,
                                        uint32_t channel_count,
                                        uint32_t sample_rate,
                                        uint32_t edit_rate_num,
                                        uint32_t edit_rate_den,
                                        char *err_buf, size_t err_buf_len);

/* Returns the exact number of bytes expected per edit-unit frame
 * (samples_per_frame * channels * 3). */
uint32_t asdcp_pcm_frame_buffer_size(asdcp_pcm_writer *writer);

int asdcp_pcm_write_frame(asdcp_pcm_writer *writer,
                          const uint8_t *frame, size_t frame_len,
                          char *err_buf, size_t err_buf_len);

int asdcp_pcm_writer_finish(asdcp_pcm_writer *writer,
                            char *err_buf, size_t err_buf_len);

void asdcp_pcm_writer_abort(asdcp_pcm_writer *writer);

/* --- Validation readers --- */

typedef struct asdcp_j2k_info {
    uint32_t frame_count;
    uint32_t stored_width;
    uint32_t stored_height;
    uint32_t edit_rate_num;
    uint32_t edit_rate_den;
    uint8_t  asset_uuid[16];
} asdcp_j2k_info;

typedef struct asdcp_pcm_info {
    uint32_t frame_count;
    uint32_t channel_count;
    uint32_t quantization_bits;
    uint32_t sample_rate_num;
    uint32_t sample_rate_den;
    uint8_t  asset_uuid[16];
} asdcp_pcm_info;

int asdcp_read_j2k_info(const char *path, asdcp_j2k_info *out,
                        char *err_buf, size_t err_buf_len);

int asdcp_read_pcm_info(const char *path, asdcp_pcm_info *out,
                        char *err_buf, size_t err_buf_len);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* ASDCP_SHIM_H */
