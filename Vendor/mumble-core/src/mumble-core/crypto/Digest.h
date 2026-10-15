// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#ifndef MUMBLE_CRYPTO_DIGEST_H_
#define MUMBLE_CRYPTO_DIGEST_H_

#include <cstdint>
#include <span>
#include <vector>

struct evp_md_ctx_st;

namespace Mumble {
namespace Crypto {

	enum class DigestAlgorithm { Sha1, Sha256 };

	/// Incremental SHA-1/SHA-256 over OpenSSL. CryptographicHash is the Qt-facing wrapper of this.
	class Digest {
	public:
		explicit Digest(DigestAlgorithm algorithm);
		~Digest();

		Digest(const Digest &)            = delete;
		Digest &operator=(const Digest &) = delete;

		/// Adding data after result() has been called is an error: the object goes into an error state and
		/// every later result() is empty.
		void addData(std::span< const std::uint8_t > data);

		/// Finalizes the digest and returns it. Calling it again returns the same digest. Empty on failure.
		std::vector< std::uint8_t > result();

		static std::vector< std::uint8_t > hash(std::span< const std::uint8_t > data, DigestAlgorithm algorithm);

	private:
		evp_md_ctx_st *m_mdctx = nullptr;

		/// Filled in by result(), after which m_mdctx is finalized and can't be used anymore, so result() and
		/// addData() must guard against that possibility.
		std::vector< std::uint8_t > m_result;

		/// If m_mdctx is set, destroys it and sets m_mdctx to nullptr.
		void cleanupMdctx();
	};

} // namespace Crypto
} // namespace Mumble

#endif // MUMBLE_CRYPTO_DIGEST_H_
