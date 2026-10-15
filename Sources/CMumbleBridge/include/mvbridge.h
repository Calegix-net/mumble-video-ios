// C surface over mumble-core (MediaSession, ControlReader), Opus and libvpx for the Swift client.
//
// mumble-core's API is C++20 with move-only pimpl classes and std::span, which Swift's C++ interop does not
// import reliably; this header is plain C so it imports as-is. Everything the core produces for one call
// (audio, video units, pongs, NACKs for us, datagrams and control messages to send) is buffered in the
// session and handed out by mv_session_drain, once, through a table of callbacks. Pointers passed to a
// callback are only valid during that callback.

#ifndef MVBRIDGE_H
#define MVBRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *mv_core_version(void);

/// Core log lines (level 0 info, 1 warning, 2 fatal; fatal is followed by abort()).
typedef void (*mv_log_fn)(int level, const char *message);
void mv_set_log_handler(mv_log_fn handler);

// --- control channel framing (TLS) ------------------------------------------------------------------

/// Frames one control message: 2-byte type, 4-byte length (big-endian), payload. Writes into out (which
/// must hold len + 6 bytes) and returns the framed length.
size_t mv_frame_control(uint16_t type, const uint8_t *payload, size_t len, uint8_t *out);

typedef struct mv_control_reader mv_control_reader;
mv_control_reader *mv_control_reader_create(void);
void mv_control_reader_destroy(mv_control_reader *reader);
/// Appends bytes read from the TLS stream. False if the peer announced an oversize message (drop the link).
bool mv_control_reader_feed(mv_control_reader *reader, const uint8_t *bytes, size_t len);
/// Calls fn for every complete message buffered so far.
void mv_control_reader_drain(mv_control_reader *reader, void *ctx,
							 void (*fn)(void *ctx, uint16_t type, const uint8_t *payload, size_t len));

// --- media session (UDP voice and video) ------------------------------------------------------------

typedef struct mv_session mv_session;

typedef struct {
	uint32_t sender_session;
	uint64_t frame_number;
	uint32_t context; // 0 normal, 1 shout, 2 whisper, 3 listen
	const uint8_t *opus;
	size_t opus_len;
	bool is_last_frame;
	float volume_factor;
} mv_audio_packet;

typedef struct {
	uint32_t sender_session;
	uint32_t stream_id;
	uint64_t frame_number;
	uint32_t unit_id;
	bool is_keyframe;
	bool is_frame_end;
	uint64_t capture_timestamp_usec;
	uint32_t x, y, width, height;
	const uint8_t *payload;
	size_t payload_len;
} mv_video_unit;

/// Callbacks for mv_session_drain. Any may be NULL to ignore that kind of event.
typedef struct {
	void *ctx;
	void (*audio)(void *ctx, const mv_audio_packet *packet);
	void (*video)(void *ctx, const mv_video_unit *unit);
	void (*pong)(void *ctx, uint64_t timestamp);
	/// A serialised MumbleUDP.VideoNack: a viewer asking for parts of one of our streams again.
	void (*nack_for_us)(void *ctx, const uint8_t *bytes, size_t len);
	/// Send over UDP as-is.
	void (*datagram)(void *ctx, const uint8_t *bytes, size_t len);
	/// Send over the control channel as-is (already framed).
	void (*control)(void *ctx, const uint8_t *bytes, size_t len);
} mv_sink;

typedef struct {
	uint32_t audio_good, audio_late, audio_lost, audio_resync;
	uint64_t video_replays, video_too_old, video_auth_failures;
} mv_stats;

mv_session *mv_session_create(void);
void mv_session_destroy(mv_session *session);
void mv_session_set_server_version(mv_session *session, uint64_t version_v2);
/// true: media datagrams carry the leading channel byte (servers that advertise video); false: plain audio.
void mv_session_set_channel_framing(mv_session *session, bool channel_byte);
/// Handles a CryptSetup payload (full key, server nonce resync, or a request for our nonce).
bool mv_session_crypt_setup(mv_session *session, const uint8_t *payload, size_t len);
bool mv_session_is_keyed(const mv_session *session);
void mv_session_receive_datagram(mv_session *session, const uint8_t *bytes, size_t len, uint64_t now_usec);
void mv_session_receive_tunnelled(mv_session *session, const uint8_t *bytes, size_t len);
/// Hands out and clears everything the session produced since the last drain.
void mv_session_drain(mv_session *session, const mv_sink *sink);

/// Encrypted UDP ping / audio datagram, written to out (capacity out_cap). Returns the length, or 0 if the
/// session is not keyed or out is too small.
size_t mv_session_make_ping(mv_session *session, uint64_t timestamp, uint8_t *out, size_t out_cap);
size_t mv_session_make_audio(mv_session *session, const uint8_t *opus, size_t opus_len, uint64_t frame_number,
							 uint32_t target, bool is_last, uint8_t *out, size_t out_cap);
/// Fragments and encrypts one video unit (its sender_session is ignored); fn is called for each datagram.
/// Returns the number of datagrams (0 if not keyed, framing is plain, or the unit is too large).
size_t mv_session_make_video(mv_session *session, const mv_video_unit *unit, void *ctx,
							 void (*fn)(void *ctx, const uint8_t *bytes, size_t len));
void mv_session_remove_sender(mv_session *session, uint32_t sender_session);
mv_stats mv_session_stats(const mv_session *session);

// --- Opus (48 kHz mono, 10 ms frames are 480 samples) -----------------------------------------------

typedef struct mv_opus_decoder mv_opus_decoder;
mv_opus_decoder *mv_opus_decoder_create(void);
void mv_opus_decoder_destroy(mv_opus_decoder *decoder);
/// Decodes one packet (NULL/0 for packet-loss concealment of `max_samples`). Returns samples or < 0.
int mv_opus_decode(mv_opus_decoder *decoder, const uint8_t *packet, size_t len, int16_t *pcm, int max_samples);
int mv_opus_packet_samples(const uint8_t *packet, size_t len);

typedef struct mv_opus_encoder mv_opus_encoder;
/// VOIP application, the given bitrate in bits per second.
mv_opus_encoder *mv_opus_encoder_create(int bitrate);
void mv_opus_encoder_destroy(mv_opus_encoder *encoder);
int mv_opus_encode(mv_opus_encoder *encoder, const int16_t *pcm, int samples, uint8_t *out, size_t out_cap);
const char *mv_opus_version(void);

// --- libvpx decoding (VP8 / VP9) ---------------------------------------------------------------------

typedef struct mv_vpx_decoder mv_vpx_decoder;
/// codec: 8 or 9.
mv_vpx_decoder *mv_vpx_decoder_create(int codec);
void mv_vpx_decoder_destroy(mv_vpx_decoder *decoder);

/// One decoded I420 frame; planes are valid until the next decode call.
typedef struct {
	uint32_t width, height;
	const uint8_t *y, *u, *v;
	int y_stride, u_stride, v_stride;
} mv_i420_frame;

/// Decodes one compressed frame. Returns 1 and fills frame if a picture is ready, 0 if none, < 0 on error.
int mv_vpx_decode(mv_vpx_decoder *decoder, const uint8_t *data, size_t len, mv_i420_frame *frame);

// --- libvpx encoding (VP8, realtime) ---------------------------------------------------------------

typedef struct mv_vpx_encoder mv_vpx_encoder;
mv_vpx_encoder *mv_vpx_encoder_create(uint32_t width, uint32_t height, uint32_t fps, uint32_t bitrate_kbps);
void mv_vpx_encoder_destroy(mv_vpx_encoder *encoder);
/// Encodes one I420 frame (tightly packed planes). fn is called once per output packet.
int mv_vpx_encode(mv_vpx_encoder *encoder, const uint8_t *y, const uint8_t *u, const uint8_t *v, int64_t pts,
				  bool force_keyframe, void *ctx,
				  void (*fn)(void *ctx, const uint8_t *data, size_t len, bool keyframe));

#ifdef __cplusplus
}
#endif

#endif // MVBRIDGE_H
