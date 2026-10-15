// Copyright The Mumble Developers. All rights reserved.
// Use of this source code is governed by a BSD-style license
// that can be found in the LICENSE file at the root of the
// Mumble source tree or at <https://www.mumble.info/LICENSE>.

#include "Digest.h"

#include <openssl/evp.h>

#include <cassert>

namespace Mumble {
namespace Crypto {

	Digest::Digest(DigestAlgorithm algorithm) {
		const EVP_MD *type = nullptr;
		switch (algorithm) {
			case DigestAlgorithm::Sha1:
				type = EVP_sha1();
				break;
			case DigestAlgorithm::Sha256:
				type = EVP_sha256();
				break;
		}

		m_mdctx = EVP_MD_CTX_create();
		if (!m_mdctx) {
			return;
		}

		if (!type || EVP_DigestInit_ex(m_mdctx, type, nullptr) != 1) {
			cleanupMdctx();
		}
	}

	Digest::~Digest() {
		cleanupMdctx();
	}

	void Digest::cleanupMdctx() {
		if (m_mdctx) {
			EVP_MD_CTX_destroy(m_mdctx);
			m_mdctx = nullptr;
		}
	}

	void Digest::addData(std::span< const std::uint8_t > data) {
		if (!m_mdctx) {
			return;
		}

		// If we have a result already, that means our m_mdctx
		// object has been finalized, and can't be used anymore.
		// In that case, transition into an error state by cleaning
		// up the mdctx -- that way, subsequent calls to result()
		// will return an empty result.
		if (!m_result.empty()) {
			cleanupMdctx();
			return;
		}

		if (EVP_DigestUpdate(m_mdctx, data.data(), data.size()) != 1) {
			cleanupMdctx();
		}
	}

	std::vector< std::uint8_t > Digest::result() {
		if (!m_mdctx) {
			return {};
		}

		// If we have a result already, that means our m_mdctx
		// object has been finalized, and can't be used anymore.
		// In that case, just return the already computed result.
		if (!m_result.empty()) {
			return m_result;
		}

		std::vector< std::uint8_t > digest(static_cast< std::size_t >(EVP_MD_CTX_size(m_mdctx)));
		if (EVP_DigestFinal_ex(m_mdctx, digest.data(), nullptr) != 1) {
			cleanupMdctx();
			return {};
		}

		m_result = std::move(digest);

		assert(!m_result.empty());

		return m_result;
	}

	std::vector< std::uint8_t > Digest::hash(std::span< const std::uint8_t > data, DigestAlgorithm algorithm) {
		Digest digest(algorithm);
		digest.addData(data);
		return digest.result();
	}

} // namespace Crypto
} // namespace Mumble
