/* asdcp_shim.cpp — see include/asdcp_shim.h. */

#include "asdcp_shim.h"

#include <AS_DCP.h>
#include <KM_fileio.h>
#include <KM_util.h>

#include <cstdio>
#include <cstring>
#include <string>

using namespace ASDCP;

namespace {

void copy_error(const Result_t &result, char *err_buf, size_t err_buf_len)
{
    if (err_buf == nullptr || err_buf_len == 0) {
        return;
    }
    std::snprintf(err_buf, err_buf_len, "%s (%s)", result.Message(), result.Label());
}

void copy_error_msg(const char *msg, char *err_buf, size_t err_buf_len)
{
    if (err_buf == nullptr || err_buf_len == 0) {
        return;
    }
    std::snprintf(err_buf, err_buf_len, "%s", msg);
}

WriterInfo make_writer_info(const asdcp_writer_config *config)
{
    WriterInfo info;
    info.LabelSetType = LS_MXF_SMPTE;
    std::memcpy(info.AssetUUID, config->asset_uuid, UUIDlen);
    if (config->company_name != nullptr) {
        info.CompanyName = config->company_name;
    }
    if (config->product_name != nullptr) {
        info.ProductName = config->product_name;
    }
    if (config->product_version != nullptr) {
        info.ProductVersion = config->product_version;
    }
    /* Derive a stable product UUID from the product name space by hashing
       is overkill here; keep asdcplib's default ProductUUID. */
    return info;
}

} // namespace

/* --- JPEG 2000 --- */

struct asdcp_j2k_writer {
    JP2K::MXFWriter writer;
    JP2K::FrameBuffer frame_buffer;
};

asdcp_j2k_writer *asdcp_j2k_writer_open(const char *path,
                                        const asdcp_writer_config *config,
                                        const uint8_t *first_frame,
                                        size_t first_frame_len,
                                        uint32_t edit_rate_num,
                                        uint32_t edit_rate_den,
                                        char *err_buf, size_t err_buf_len)
{
    if (path == nullptr || config == nullptr || first_frame == nullptr || first_frame_len == 0) {
        copy_error_msg("invalid argument", err_buf, err_buf_len);
        return nullptr;
    }

    auto *shim = new asdcp_j2k_writer();

    Result_t result = shim->frame_buffer.Capacity((ui32_t)first_frame_len);
    if (ASDCP_SUCCESS(result)) {
        std::memcpy(shim->frame_buffer.Data(), first_frame, first_frame_len);
        shim->frame_buffer.Size((ui32_t)first_frame_len);
    }

    JP2K::PictureDescriptor pdesc;
    if (ASDCP_SUCCESS(result)) {
        result = JP2K::ParseMetadataIntoDesc(shim->frame_buffer, pdesc);
    }

    if (ASDCP_SUCCESS(result)) {
        pdesc.EditRate = Rational(edit_rate_num, edit_rate_den);
        pdesc.SampleRate = pdesc.EditRate;
        pdesc.ContainerDuration = 0; // filled by Finalize()
        WriterInfo info = make_writer_info(config);
        result = shim->writer.OpenWrite(path, info, pdesc);
    }

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        delete shim;
        return nullptr;
    }
    return shim;
}

int asdcp_j2k_write_frame(asdcp_j2k_writer *writer,
                          const uint8_t *frame, size_t frame_len,
                          char *err_buf, size_t err_buf_len)
{
    if (writer == nullptr || frame == nullptr || frame_len == 0) {
        copy_error_msg("invalid argument", err_buf, err_buf_len);
        return -1;
    }

    Result_t result = writer->frame_buffer.Capacity((ui32_t)frame_len);
    if (ASDCP_SUCCESS(result)) {
        std::memcpy(writer->frame_buffer.Data(), frame, frame_len);
        writer->frame_buffer.Size((ui32_t)frame_len);
        result = writer->writer.WriteFrame(writer->frame_buffer);
    }

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        return -1;
    }
    return 0;
}

int asdcp_j2k_writer_finish(asdcp_j2k_writer *writer,
                            char *err_buf, size_t err_buf_len)
{
    if (writer == nullptr) {
        copy_error_msg("invalid argument", err_buf, err_buf_len);
        return -1;
    }

    Result_t result = writer->writer.Finalize();
    delete writer;

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        return -1;
    }
    return 0;
}

void asdcp_j2k_writer_abort(asdcp_j2k_writer *writer)
{
    delete writer;
}

/* --- PCM --- */

struct asdcp_pcm_writer {
    PCM::MXFWriter writer;
    PCM::FrameBuffer frame_buffer;
    ui32_t frame_size = 0;
};

asdcp_pcm_writer *asdcp_pcm_writer_open(const char *path,
                                        const asdcp_writer_config *config,
                                        uint32_t channel_count,
                                        uint32_t sample_rate,
                                        uint32_t edit_rate_num,
                                        uint32_t edit_rate_den,
                                        char *err_buf, size_t err_buf_len)
{
    if (path == nullptr || config == nullptr || channel_count == 0 || sample_rate == 0) {
        copy_error_msg("invalid argument", err_buf, err_buf_len);
        return nullptr;
    }

    PCM::AudioDescriptor adesc;
    adesc.EditRate = Rational(edit_rate_num, edit_rate_den);
    adesc.AudioSamplingRate = Rational(sample_rate, 1);
    adesc.Locked = 0;
    adesc.ChannelCount = channel_count;
    adesc.QuantizationBits = 24;
    adesc.BlockAlign = channel_count * 3;
    adesc.AvgBps = sample_rate * adesc.BlockAlign;
    adesc.LinkedTrackID = 2;
    adesc.ContainerDuration = 0; // filled by Finalize()

    auto *shim = new asdcp_pcm_writer();
    shim->frame_size = PCM::CalcFrameBufferSize(adesc);

    Result_t result = shim->frame_buffer.Capacity(shim->frame_size);
    if (ASDCP_SUCCESS(result)) {
        WriterInfo info = make_writer_info(config);
        result = shim->writer.OpenWrite(path, info, adesc);
    }

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        delete shim;
        return nullptr;
    }
    return shim;
}

uint32_t asdcp_pcm_frame_buffer_size(asdcp_pcm_writer *writer)
{
    return writer != nullptr ? writer->frame_size : 0;
}

int asdcp_pcm_write_frame(asdcp_pcm_writer *writer,
                          const uint8_t *frame, size_t frame_len,
                          char *err_buf, size_t err_buf_len)
{
    if (writer == nullptr || frame == nullptr || frame_len != writer->frame_size) {
        copy_error_msg("invalid argument (frame_len must equal asdcp_pcm_frame_buffer_size)",
                       err_buf, err_buf_len);
        return -1;
    }

    std::memcpy(writer->frame_buffer.Data(), frame, frame_len);
    writer->frame_buffer.Size((ui32_t)frame_len);
    Result_t result = writer->writer.WriteFrame(writer->frame_buffer);

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        return -1;
    }
    return 0;
}

int asdcp_pcm_writer_finish(asdcp_pcm_writer *writer,
                            char *err_buf, size_t err_buf_len)
{
    if (writer == nullptr) {
        copy_error_msg("invalid argument", err_buf, err_buf_len);
        return -1;
    }

    Result_t result = writer->writer.Finalize();
    delete writer;

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        return -1;
    }
    return 0;
}

void asdcp_pcm_writer_abort(asdcp_pcm_writer *writer)
{
    delete writer;
}

/* --- Validation readers --- */

int asdcp_read_j2k_info(const char *path, asdcp_j2k_info *out,
                        char *err_buf, size_t err_buf_len)
{
    if (path == nullptr || out == nullptr) {
        copy_error_msg("invalid argument", err_buf, err_buf_len);
        return -1;
    }

    Kumu::FileReaderFactory readerFactory;
    JP2K::MXFReader reader(readerFactory);
    Result_t result = reader.OpenRead(path);

    JP2K::PictureDescriptor pdesc;
    if (ASDCP_SUCCESS(result)) {
        result = reader.FillPictureDescriptor(pdesc);
    }

    WriterInfo info;
    if (ASDCP_SUCCESS(result)) {
        result = reader.FillWriterInfo(info);
    }

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        return -1;
    }

    out->frame_count = pdesc.ContainerDuration;
    out->stored_width = pdesc.StoredWidth;
    out->stored_height = pdesc.StoredHeight;
    out->edit_rate_num = (uint32_t)pdesc.EditRate.Numerator;
    out->edit_rate_den = (uint32_t)pdesc.EditRate.Denominator;
    std::memcpy(out->asset_uuid, info.AssetUUID, UUIDlen);
    return 0;
}

int asdcp_read_pcm_info(const char *path, asdcp_pcm_info *out,
                        char *err_buf, size_t err_buf_len)
{
    if (path == nullptr || out == nullptr) {
        copy_error_msg("invalid argument", err_buf, err_buf_len);
        return -1;
    }

    Kumu::FileReaderFactory readerFactory;
    PCM::MXFReader reader(readerFactory);
    Result_t result = reader.OpenRead(path);

    PCM::AudioDescriptor adesc;
    if (ASDCP_SUCCESS(result)) {
        result = reader.FillAudioDescriptor(adesc);
    }

    WriterInfo info;
    if (ASDCP_SUCCESS(result)) {
        result = reader.FillWriterInfo(info);
    }

    if (ASDCP_FAILURE(result)) {
        copy_error(result, err_buf, err_buf_len);
        return -1;
    }

    out->frame_count = adesc.ContainerDuration;
    out->channel_count = adesc.ChannelCount;
    out->quantization_bits = adesc.QuantizationBits;
    out->sample_rate_num = (uint32_t)adesc.AudioSamplingRate.Numerator;
    out->sample_rate_den = (uint32_t)adesc.AudioSamplingRate.Denominator;
    std::memcpy(out->asset_uuid, info.AssetUUID, UUIDlen);
    return 0;
}
