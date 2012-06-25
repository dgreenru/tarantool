#ifndef TARANTOOL_PICKLE_H_INCLUDED
#define TARANTOOL_PICKLE_H_INCLUDED
/*
 * Copyright (C) 2010 Mail.RU
 * Copyright (C) 2010 Yuriy Vostrikov
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
#include <stdint.h>
#include <stdbool.h>

#include <util.h>

struct tbuf;

uint8_t *save_varint32(uint8_t *target, uint32_t value);
void write_varint32(struct tbuf *b, uint32_t value);

uint8_t read_u8(struct tbuf *b);
uint16_t read_u16(struct tbuf *b);
uint32_t read_u32(struct tbuf *b);
uint64_t read_u64(struct tbuf *b);

uint32_t read_varint32(struct tbuf *buf);
void *read_field(struct tbuf *buf);

void *read_str(struct tbuf *buf, uint32_t len);

uint32_t pick_u32(void *data, void **rest);

uint32_t valid_tuple(struct tbuf *buf, uint32_t cardinality);

size_t varint32_sizeof(u32);

inline static uint32_t load_varint32(void **data)
{
	const uint8_t *b = *data;

	if (!(b[0] & 0x80)) {
		*data += 1;
		return (b[0] & 0x7f);
	}
	if (!(b[1] & 0x80)) {
		*data += 2;
		return (b[0] & 0x7f) << 7 | (b[1] & 0x7f);
	}
	if (!(b[2] & 0x80)) {
		*data += 3;
		return (b[0] & 0x7f) << 14 | (b[1] & 0x7f) << 7 | (b[2] & 0x7f);
	}
	if (!(b[3] & 0x80)) {
		*data += 4;
		return (b[0] & 0x7f) << 21 | (b[1] & 0x7f) << 14 |
			(b[2] & 0x7f) << 7 | (b[3] & 0x7f);
	}
	if (!(b[4] & 0x80)) {
		*data += 5;
		return (b[0] & 0x7f) << 28 | (b[1] & 0x7f) << 21 |
			(b[2] & 0x7f) << 14 | (b[3] & 0x7f) << 7 | (b[4] & 0x7f);
	}

	assert(false);
	return 0;
}

#endif /* TARANTOOL_PICKLE_H_INCLUDED */
