// Copyright (c) 2019 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.

// SHA256 block step.
// This is the generic version with no architecture optimizations.
// In its own file so that an architecture
// optimized verision can be substituted

module sha256

import math.bits

const (
	_K = [
		0x428a2f98,
		0x71374491,
		0xb5c0fbcf,
		0xe9b5dba5,
		0x3956c25b,
		0x59f111f1,
		0x923f82a4,
		0xab1c5ed5,
		0xd807aa98,
		0x12835b01,
		0x243185be,
		0x550c7dc3,
		0x72be5d74,
		0x80deb1fe,
		0x9bdc06a7,
		0xc19bf174,
		0xe49b69c1,
		0xefbe4786,
		0x0fc19dc6,
		0x240ca1cc,
		0x2de92c6f,
		0x4a7484aa,
		0x5cb0a9dc,
		0x76f988da,
		0x983e5152,
		0xa831c66d,
		0xb00327c8,
		0xbf597fc7,
		0xc6e00bf3,
		0xd5a79147,
		0x06ca6351,
		0x14292967,
		0x27b70a85,
		0x2e1b2138,
		0x4d2c6dfc,
		0x53380d13,
		0x650a7354,
		0x766a0abb,
		0x81c2c92e,
		0x92722c85,
		0xa2bfe8a1,
		0xa81a664b,
		0xc24b8b70,
		0xc76c51a3,
		0xd192e819,
		0xd6990624,
		0xf40e3585,
		0x106aa070,
		0x19a4c116,
		0x1e376c08,
		0x2748774c,
		0x34b0bcb5,
		0x391c0cb3,
		0x4ed8aa4a,
		0x5b9cca4f,
		0x682e6ff3,
		0x748f82ee,
		0x78a5636f,
		0x84c87814,
		0x8cc70208,
		0x90befffa,
		0xa4506ceb,
		0xbef9a3f7,
		0xc67178f2,
	]
)

fn block_generic(dig mut Digest, p_ []byte) {
	mut p := p_

	mut w := [u32(0)].repeat(64)
	
	mut h0 := dig.h[0]
	mut h1 := dig.h[1]
	mut h2 := dig.h[2]
	mut h3 := dig.h[3]
	mut h4 := dig.h[4]
	mut h5 := dig.h[5]
	mut h6 := dig.h[6]
	mut h7 := dig.h[7]

	for p.len >= Chunk {
		// Can interlace the computation of w with the
		// rounds below if needed for speed.
		for i := 0; i < 16; i++ {
			j := i * 4
			w[i] = u32(u32(p[j])<<u32(24)) | u32(u32(p[j+1])<<u32(16)) | u32(u32(p[j+2])<<u32(8)) | u32(p[j+3])
		}
		for i := 16; i < 64; i++ {
			v1 := w[i-2]
			t1 := (bits.rotate_left_32(v1, -17)) ^ (bits.rotate_left_32(v1, -19)) ^ u32((v1 >> u32(10)))
			v2 := w[i-15]
			t2 := (bits.rotate_left_32(v2, -7)) ^ (bits.rotate_left_32(v2, -18)) ^ u32((v2 >> u32(3)))
			w[i] = t1 + w[i-7] + t2 + w[i-16]
		}

		mut a := h0
		mut b := h1
		mut c := h2
		mut d := h3
		mut e := h4
		mut f := h5
		mut g := h6
		mut h := h7

		for i := 0; i < 64; i++ {
			t1 := h + ((bits.rotate_left_32(e, -6)) ^ (bits.rotate_left_32(e, -11)) ^ (bits.rotate_left_32(e, -25))) + ((e & f) ^ (~e & g)) + u32(_K[i]) + w[i]

			t2 := ((bits.rotate_left_32(a, -2)) ^ (bits.rotate_left_32(a, -13)) ^ (bits.rotate_left_32(a, -22))) + ((a & b) ^ (a & c) ^ (b & c))

			h = g
			g = f
			f = e
			e = d + t1
			d = c
			c = b
			b = a
			a = t1 + t2
		}

		h0 += a
		h1 += b
		h2 += c
		h3 += d
		h4 += e
		h5 += f
		h6 += g
		h7 += h

		if Chunk >= p.len {
			p = []byte
		} else {
			p = p.right(Chunk)
		}
	}

	dig.h[0] = h0
	dig.h[1] = h1
	dig.h[2] = h2
	dig.h[3] = h3
	dig.h[4] = h4
	dig.h[5] = h5
	dig.h[6] = h6
	dig.h[7] = h7
}
