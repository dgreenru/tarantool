#ifndef TARANTOOL_IPROTO_H_INCLUDED
#define TARANTOOL_IPROTO_H_INCLUDED
/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met: 1. Redistributions of source code must
 * retain the above copyright notice, this list of conditions and
 * the following disclaimer.  2. Redistributions in binary form
 * must reproduce the above copyright notice, this list of
 * conditions and the following disclaimer in the documentation
 * and/or other materials provided with the distribution.
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

#include <net_io.h>
#include <stdint.h>

#include <third_party/queue.h>


@class IProtoConnection;
struct batch;
struct inbuf;

enum {
	/** Maximal iproto package body length (2GiB) */
	IPROTO_BODY_LEN_MAX = 2147483648,
};

/*
 * struct iproto_header and struct iproto_header_retcode
 * share common prefix {msg_code, len, sync}
 */

struct iproto_header {
	uint32_t msg_code;
	uint32_t len;
	uint32_t sync;
	uint8_t data[];
} __attribute__((packed));

struct iproto_header_retcode {
	uint32_t msg_code;
	uint32_t len;
	uint32_t sync;
	uint32_t ret_code;
} __attribute__((packed));


static inline struct iproto_header *iproto(const struct tbuf *t)
{
	return (struct iproto_header *)t->data;
}


/**
 * IProto Service.
 */
@interface IProtoService: Service {
}

/* Entry point. */
- (void) process: (struct batch *)batch;

/* Extension point. */
- (void) process: (uint32_t)msg_code :(struct tbuf *)request;

@end


/**
 * IProto Connection.
 */
@interface IProtoConnection: ServiceConnection {
@public
	struct batch *batch;
}

- (int) fd;

@end


void iproto_init(void);

#endif
