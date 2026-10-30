#ifndef CFFMPEG_SHIM_H
#define CFFMPEG_SHIM_H

#include <math.h>
#include <string.h>
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/display.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

static inline int cff_error_eagain(void) { return AVERROR(EAGAIN); }
static inline int cff_error_eof(void) { return AVERROR_EOF; }
static inline int cff_error_eio(void) { return AVERROR(EIO); }
static inline int cff_averror_invaliddata(void) { return AVERROR_INVALIDDATA; }
static inline int cff_averror_stream_not_found(void) { return AVERROR_STREAM_NOT_FOUND; }
static inline int cff_averror_muxer_not_found(void) { return AVERROR_MUXER_NOT_FOUND; }
static inline int64_t cff_nopts(void) { return AV_NOPTS_VALUE; }

/// Clockwise rotation (0, 90, 180, 270) needed to show the stream upright. A mirrored matrix gives the turn
/// without its horizontal flip (read on its own, a flip would count as half a turn and show the picture upside down).
static inline int cff_stream_rotation_cw(const AVStream *st) {
    const AVPacketSideData *sd = av_packet_side_data_get(st->codecpar->coded_side_data,
                                                         st->codecpar->nb_coded_side_data,
                                                         AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * sizeof(int32_t)) return 0;
    int32_t m[9];
    memcpy(m, sd->data, sizeof(m));
    if ((int64_t)m[0] * m[4] - (int64_t)m[1] * m[3] < 0) {
        m[0] = -m[0];
        m[3] = -m[3];
    }
    double ccw = av_display_rotation_get(m);
    if (isnan(ccw)) return 0;
    int cw = (int)(lround(-ccw) % 360);
    if (cw < 0) cw += 360;
    return (cw + 45) / 90 * 90 % 360;
}

/// The CVPixelBufferRef carried by an AV_PIX_FMT_VIDEOTOOLBOX frame.
static inline void *cff_frame_hw_buffer(const AVFrame *f) { return f->data[3]; }

/// sws_scale of a whole frame into a two-plane destination (NV12 / P010).
static inline int cff_sws_scale_frame(struct SwsContext *sws, const AVFrame *src,
                                      uint8_t *dst0, int stride0, uint8_t *dst1, int stride1) {
    uint8_t *dst[4] = { dst0, dst1, NULL, NULL };
    int strides[4] = { stride0, stride1, 0, 0 };
    return sws_scale(sws, (const uint8_t * const *)src->data, src->linesize, 0, src->height, dst, strides);
}

/// swr_convert into two planar float channels. Pass in == NULL to flush.
static inline int cff_swr_convert_frame(SwrContext *swr, float *out0, float *out1, int out_count,
                                        const AVFrame *in) {
    uint8_t *out[2] = { (uint8_t *)out0, (uint8_t *)out1 };
    return swr_convert(swr, out, out_count,
                       in ? (const uint8_t **)in->extended_data : NULL,
                       in ? in->nb_samples : 0);
}

/// Whether a stream copy into `ofmt` can keep the input's codec tag (the ffmpeg tool's rule): the muxer has no
/// tag table, the tag maps to the same codec there, or the muxer knows no tag for the codec at all.
static inline int cff_muxer_keeps_codec_tag(const AVOutputFormat *ofmt, const AVCodecParameters *par) {
    unsigned int tag;
    return !ofmt->codec_tag || av_codec_get_id(ofmt->codec_tag, par->codec_tag) == par->codec_id
        || !av_codec_get_tag2(ofmt->codec_tag, par->codec_id, &tag);
}

static inline int cff_pix_fmt_depth(int fmt) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get((enum AVPixelFormat)fmt);
    return d ? d->comp[0].depth : 8;
}

#endif
