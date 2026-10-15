#include "mvbridge.h"

#include <mumble-core/MumbleCore.h>
#include <opus/opus.h>
#include <vpx/vp8cx.h>
#include <vpx/vp8dx.h>
#include <vpx/vpx_decoder.h>
#include <vpx/vpx_encoder.h>

#include <cstring>
#include <optional>
#include <span>

using namespace MumbleCore;

namespace {
ByteView view(const uint8_t *bytes, size_t len) {
	return ByteView(bytes, len);
}

size_t copyOut(const std::optional< Bytes > &bytes, uint8_t *out, size_t cap) {
	if (!bytes || bytes->size() > cap) {
		return 0;
	}
	std::memcpy(out, bytes->data(), bytes->size());
	return bytes->size();
}

mv_log_fn g_log = nullptr;

void forwardLog(LogLevel level, const char *message) {
	if (g_log) {
		g_log(level == LogLevel::Info ? 0 : level == LogLevel::Warning ? 1 : 2, message);
	}
}
} // namespace

const char *mv_core_version(void) {
	return MumbleCore::version();
}

void mv_set_log_handler(mv_log_fn handler) {
	g_log = handler;
	setLogHandler(handler ? forwardLog : nullptr);
}

// --- control ------------------------------------------------------------------------------------------

size_t mv_frame_control(uint16_t type, const uint8_t *payload, size_t len, uint8_t *out) {
	const Bytes framed = frameControlMessage(type, view(payload, len));
	std::memcpy(out, framed.data(), framed.size());
	return framed.size();
}

struct mv_control_reader {
	ControlReader reader;
};

mv_control_reader *mv_control_reader_create(void) {
	return new mv_control_reader();
}

void mv_control_reader_destroy(mv_control_reader *reader) {
	delete reader;
}

bool mv_control_reader_feed(mv_control_reader *reader, const uint8_t *bytes, size_t len) {
	return reader->reader.feed(view(bytes, len));
}

void mv_control_reader_drain(mv_control_reader *reader, void *ctx,
							 void (*fn)(void *ctx, uint16_t type, const uint8_t *payload, size_t len)) {
	while (std::optional< ControlMessage > message = reader->reader.next()) {
		fn(ctx, message->type, message->payload.data(), message->payload.size());
	}
}

// --- media session ------------------------------------------------------------------------------------

struct mv_session {
	MediaSession session;
	MediaEvents events;
};

mv_session *mv_session_create(void) {
	return new mv_session();
}

void mv_session_destroy(mv_session *session) {
	delete session;
}

void mv_session_set_server_version(mv_session *session, uint64_t version_v2) {
	session->session.setServerVersion(version_v2);
}

void mv_session_set_channel_framing(mv_session *session, bool channel_byte) {
	session->session.setUdpFraming(channel_byte ? UdpFraming::ChannelByte : UdpFraming::Plain);
}

bool mv_session_crypt_setup(mv_session *session, const uint8_t *payload, size_t len) {
	return session->session.handleCryptSetup(view(payload, len), session->events);
}

bool mv_session_is_keyed(const mv_session *session) {
	return session->session.isKeyed();
}

void mv_session_receive_datagram(mv_session *session, const uint8_t *bytes, size_t len, uint64_t now_usec) {
	session->session.receiveDatagram(view(bytes, len), now_usec, session->events);
}

void mv_session_receive_tunnelled(mv_session *session, const uint8_t *bytes, size_t len) {
	session->session.receiveTunnelled(view(bytes, len), session->events);
}

void mv_session_drain(mv_session *session, const mv_sink *sink) {
	MediaEvents &e = session->events;
	if (sink->audio) {
		for (const AudioPacket &a : e.audio) {
			const mv_audio_packet p = { a.senderSession, a.frameNumber,  a.context,       a.opus.data(),
										a.opus.size(),   a.isLastFrame, a.volumeFactor };
			sink->audio(sink->ctx, &p);
		}
	}
	if (sink->video) {
		for (const VideoUnit &v : e.video) {
			const mv_video_unit u = { v.senderSession, v.streamID, v.frameNumber, v.unitID, v.isKeyframe,
									  v.isFrameEnd,    v.captureTimestampUsec,
									  v.x,             v.y,        v.width,       v.height, v.payload.data(),
									  v.payload.size() };
			sink->video(sink->ctx, &u);
		}
	}
	if (sink->pong) {
		for (std::uint64_t t : e.pongs) {
			sink->pong(sink->ctx, t);
		}
	}
	if (sink->nack_for_us) {
		for (const Bytes &b : e.videoNacksForUs) {
			sink->nack_for_us(sink->ctx, b.data(), b.size());
		}
	}
	if (sink->datagram) {
		for (const Bytes &b : e.datagramsToSend) {
			sink->datagram(sink->ctx, b.data(), b.size());
		}
	}
	if (sink->control) {
		for (const Bytes &b : e.controlToSend) {
			sink->control(sink->ctx, b.data(), b.size());
		}
	}
	e.clear();
}

size_t mv_session_make_ping(mv_session *session, uint64_t timestamp, uint8_t *out, size_t out_cap) {
	return copyOut(session->session.makePing(timestamp), out, out_cap);
}

size_t mv_session_make_audio(mv_session *session, const uint8_t *opus, size_t opus_len, uint64_t frame_number,
							 uint32_t target, bool is_last, uint8_t *out, size_t out_cap) {
	return copyOut(session->session.makeAudio(view(opus, opus_len), frame_number, target, is_last), out, out_cap);
}

size_t mv_session_make_video(mv_session *session, const mv_video_unit *u, void *ctx,
							 void (*fn)(void *ctx, const uint8_t *bytes, size_t len)) {
	VideoUnit unit;
	unit.streamID             = u->stream_id;
	unit.frameNumber          = u->frame_number;
	unit.unitID               = u->unit_id;
	unit.isKeyframe           = u->is_keyframe;
	unit.isFrameEnd           = u->is_frame_end;
	unit.captureTimestampUsec = u->capture_timestamp_usec;
	unit.x                    = u->x;
	unit.y                    = u->y;
	unit.width                = u->width;
	unit.height               = u->height;
	unit.payload.assign(u->payload, u->payload + u->payload_len);
	const std::vector< Bytes > datagrams = session->session.makeVideo(unit);
	for (const Bytes &d : datagrams) {
		fn(ctx, d.data(), d.size());
	}
	return datagrams.size();
}

void mv_session_remove_sender(mv_session *session, uint32_t sender_session) {
	session->session.removeSender(sender_session);
}

mv_stats mv_session_stats(const mv_session *session) {
	const MediaStats s = session->session.stats();
	return { s.audioGood, s.audioLate, s.audioLost, s.audioResync, s.videoReplays, s.videoTooOld,
			 s.videoAuthFailures };
}

// --- Opus ---------------------------------------------------------------------------------------------

struct mv_opus_decoder {
	OpusDecoder *dec;
};

mv_opus_decoder *mv_opus_decoder_create(void) {
	int err           = 0;
	OpusDecoder *dec  = opus_decoder_create(48000, 1, &err);
	return err == OPUS_OK ? new mv_opus_decoder{ dec } : nullptr;
}

void mv_opus_decoder_destroy(mv_opus_decoder *decoder) {
	if (decoder) {
		opus_decoder_destroy(decoder->dec);
		delete decoder;
	}
}

int mv_opus_decode(mv_opus_decoder *decoder, const uint8_t *packet, size_t len, int16_t *pcm, int max_samples) {
	return opus_decode(decoder->dec, packet, static_cast< opus_int32 >(len), pcm, max_samples, 0);
}

int mv_opus_packet_samples(const uint8_t *packet, size_t len) {
	return opus_packet_get_nb_samples(packet, static_cast< opus_int32 >(len), 48000);
}

struct mv_opus_encoder {
	OpusEncoder *enc;
};

mv_opus_encoder *mv_opus_encoder_create(int bitrate) {
	int err          = 0;
	OpusEncoder *enc = opus_encoder_create(48000, 1, OPUS_APPLICATION_VOIP, &err);
	if (err != OPUS_OK) {
		return nullptr;
	}
	opus_encoder_ctl(enc, OPUS_SET_BITRATE(bitrate));
	return new mv_opus_encoder{ enc };
}

void mv_opus_encoder_destroy(mv_opus_encoder *encoder) {
	if (encoder) {
		opus_encoder_destroy(encoder->enc);
		delete encoder;
	}
}

int mv_opus_encode(mv_opus_encoder *encoder, const int16_t *pcm, int samples, uint8_t *out, size_t out_cap) {
	return opus_encode(encoder->enc, pcm, samples, out, static_cast< opus_int32 >(out_cap));
}

const char *mv_opus_version(void) {
	return opus_get_version_string();
}

// --- libvpx -------------------------------------------------------------------------------------------

struct mv_vpx_decoder {
	vpx_codec_ctx_t ctx;
};

mv_vpx_decoder *mv_vpx_decoder_create(int codec) {
	auto *d                   = new mv_vpx_decoder();
	vpx_codec_iface_t *iface  = codec == 9 ? vpx_codec_vp9_dx() : vpx_codec_vp8_dx();
	vpx_codec_dec_cfg_t cfg   = {};
	cfg.threads               = 2;
	if (vpx_codec_dec_init(&d->ctx, iface, &cfg, 0) != VPX_CODEC_OK) {
		delete d;
		return nullptr;
	}
	return d;
}

void mv_vpx_decoder_destroy(mv_vpx_decoder *decoder) {
	if (decoder) {
		vpx_codec_destroy(&decoder->ctx);
		delete decoder;
	}
}

int mv_vpx_decode(mv_vpx_decoder *decoder, const uint8_t *data, size_t len, mv_i420_frame *frame) {
	if (vpx_codec_decode(&decoder->ctx, data, static_cast< unsigned int >(len), nullptr, 0) != VPX_CODEC_OK) {
		return -1;
	}
	vpx_codec_iter_t iter = nullptr;
	vpx_image_t *img      = vpx_codec_get_frame(&decoder->ctx, &iter);
	if (!img) {
		return 0;
	}
	if (img->fmt != VPX_IMG_FMT_I420) {
		return -2;
	}
	frame->width    = img->d_w;
	frame->height   = img->d_h;
	frame->y        = img->planes[VPX_PLANE_Y];
	frame->u        = img->planes[VPX_PLANE_U];
	frame->v        = img->planes[VPX_PLANE_V];
	frame->y_stride = img->stride[VPX_PLANE_Y];
	frame->u_stride = img->stride[VPX_PLANE_U];
	frame->v_stride = img->stride[VPX_PLANE_V];
	return 1;
}

// --- libvpx encoding ----------------------------------------------------------------------------------

struct mv_vpx_encoder {
	vpx_codec_ctx_t ctx;
	vpx_image_t img;
	uint32_t width, height;
};

mv_vpx_encoder *mv_vpx_encoder_create(uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate_kbps) {
	vpx_codec_enc_cfg_t cfg;
	if (vpx_codec_enc_config_default(vpx_codec_vp8_cx(), &cfg, 0) != VPX_CODEC_OK) {
		return nullptr;
	}
	cfg.g_w               = width;
	cfg.g_h               = height;
	cfg.g_timebase.num    = 1;
	cfg.g_timebase.den    = static_cast< int >(fps);
	cfg.rc_target_bitrate = bitrate_kbps;
	cfg.rc_end_usage      = VPX_CBR;
	cfg.g_lag_in_frames   = 0;
	cfg.g_error_resilient = VPX_ERROR_RESILIENT_DEFAULT;
	cfg.kf_max_dist       = 120;
	cfg.g_threads         = 2;
	auto *e               = new mv_vpx_encoder();
	if (vpx_codec_enc_init(&e->ctx, vpx_codec_vp8_cx(), &cfg, 0) != VPX_CODEC_OK) {
		delete e;
		return nullptr;
	}
	vpx_codec_control(&e->ctx, VP8E_SET_CPUUSED, 8);
	e->width  = width;
	e->height = height;
	return e;
}

void mv_vpx_encoder_destroy(mv_vpx_encoder *encoder) {
	if (encoder) {
		vpx_codec_destroy(&encoder->ctx);
		delete encoder;
	}
}

int mv_vpx_encode(mv_vpx_encoder *e, const uint8_t *y, const uint8_t *u, const uint8_t *v, int64_t pts,
				  bool force_keyframe, void *ctx, void (*fn)(void *ctx, const uint8_t *data, size_t len, bool keyframe)) {
	vpx_image_t img;
	vpx_img_wrap(&img, VPX_IMG_FMT_I420, e->width, e->height, 1, const_cast< uint8_t * >(y));
	img.planes[VPX_PLANE_U] = const_cast< uint8_t * >(u);
	img.planes[VPX_PLANE_V] = const_cast< uint8_t * >(v);
	img.stride[VPX_PLANE_Y] = static_cast< int >(e->width);
	img.stride[VPX_PLANE_U] = static_cast< int >((e->width + 1) / 2);
	img.stride[VPX_PLANE_V] = static_cast< int >((e->width + 1) / 2);
	if (vpx_codec_encode(&e->ctx, &img, pts, 1, force_keyframe ? VPX_EFLAG_FORCE_KF : 0, VPX_DL_REALTIME)
		!= VPX_CODEC_OK) {
		return -1;
	}
	int packets                 = 0;
	vpx_codec_iter_t iter       = nullptr;
	const vpx_codec_cx_pkt_t *p = nullptr;
	while ((p = vpx_codec_get_cx_data(&e->ctx, &iter))) {
		if (p->kind == VPX_CODEC_CX_FRAME_PKT) {
			fn(ctx, static_cast< const uint8_t * >(p->data.frame.buf), p->data.frame.sz,
			   (p->data.frame.flags & VPX_FRAME_IS_KEY) != 0);
			packets++;
		}
	}
	return packets;
}
