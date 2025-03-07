// Copyright (c) 2019 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.

// This is the generic version with no architecture optimizations.
// In its own file so that an architecture
// optimized verision can be substituted

module sha1

import math.bits

const (
	_K0 = 0x5A827999
	_K1 = 0x6ED9EBA1
	_K2 = 0x8F1BBCDC
	_K3 = 0xCA62C1D6
)

fn block_generic(dig mut Digest, p_ []byte) {
	mut p := p_
	mut w := [u32(0)].repeat(16)
	mut h0 := dig.h[0]
	mut h1 := dig.h[1]
	mut h2 := dig.h[2]
	mut h3 := dig.h[3]
	mut h4 := dig.h[4]
	for p.len >= Chunk {
		// Can interlace the computation of w with the
		// rounds below if needed for speed.
		for i := 0; i < 16; i++ {
			j := i * 4
			w[i] = u32(u32(p[j])<<u32(24)) | u32(u32(p[j+1])<<u32(16)) | u32(u32(p[j+2])<<u32(8)) | u32(u32(p[j+3]))
		}

		mut a := h0
		mut b := h1
		mut c := h2
		mut d := h3
		mut e := h4

		// Each of the four 20-iteration rounds
		// differs only in the computation of f and
		// the choice of K (_K0, _K1, etc).
		mut i := 0
		for i < 16 {
			f := u32(b&c | (~b)&d)
			t := bits.rotate_left_32(a, 5) + f + e + w[i&0xf] + u32(_K0)
			e = d
			d = c
			c = bits.rotate_left_32(b, 30)
			b = a
			a = t
			i++
		}
		for i < 20 {
			tmp := w[(i-3)&0xf] ^ w[(i-8)&0xf] ^ w[(i-14)&0xf] ^ w[(i)&0xf]
			w[i&0xf] = u32(tmp<<u32(1)) | u32(tmp>>u32(32-1))
			f := b&c | (~b)&d
			t := bits.rotate_left_32(a, 5) + f + e + w[i&0xf] + u32(_K0)
			e = d
			d = c
			c = bits.rotate_left_32(b, 30)
			b = a
			a = t
			i++
		}
		for i < 40 {
			tmp := w[(i-3)&0xf] ^ w[(i-8)&0xf] ^ w[(i-14)&0xf] ^ w[(i)&0xf]
			w[i&0xf] = u32(tmp<<u32(1)) | u32(tmp>>u32(32-1))
			f := b ^ c ^ d
			t := bits.rotate_left_32(a, 5) + f + e + w[i&0xf] + u32(_K1)
			e = d
			d = c
			c = bits.rotate_left_32(b, 30)
			b = a
			a = t
			i++
		}
		for i < 60 {
			tmp := w[(i-3)&0xf] ^ w[(i-8)&0xf] ^ w[(i-14)&0xf] ^ w[(i)&0xf]
			w[i&0xf] = u32(tmp<<u32(1)) | u32(tmp>>u32(32-1))
			f := ((b | c) & d) | (b & c)
			t := bits.rotate_left_32(a, 5) + f + e + w[i&0xf] + u32(_K2)
			e = d
			d = c
			c = bits.rotate_left_32(b, 30)
			b = a
			a = t
			i++
		}
		for i < 80 {
			tmp := w[(i-3)&0xf] ^ w[(i-8)&0xf] ^ w[(i-14)&0xf] ^ w[(i)&0xf]
			w[i&0xf] = u32(tmp<<u32(1)) | u32(tmp>>u32(32-1))
			f := b ^ c ^ d
			t := bits.rotate_left_32(a, 5) + f + e + w[i&0xf] + u32(_K3)
			e = d
			d = c
			c = bits.rotate_left_32(b, 30)
			b = a
			a = t
			i++
		}

		h0 += a
		h1 += b
		h2 += c
		h3 += d
		h4 += e

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
}
