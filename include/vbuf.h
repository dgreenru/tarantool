#ifndef TARANTOOL_VBUF_H_INCLUDED
#define TARANTOOL_VBUF_H_INCLUDED
/*
 * Redistribution and use in source and binary forms, with or
 * without modification, are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above
 *    copyright notice, this list of conditions and the
 *    following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above
 *    copyright notice, this list of conditions and the following
 *    disclaimer in the documentation and/or other materials
 *    provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY <COPYRIGHT HOLDER> ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
 * TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL
 * <COPYRIGHT HOLDER> OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR
 * BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF
 * THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <tbuf.h>
#include <palloc.h>
#include <stdbool.h>
#include <sys/uio.h>

@class CoConnection;

struct vbuf
{
	struct palloc_pool *pool;
	struct tbuf *iov;
	struct tbuf *cleanup;
	size_t iov_cnt;
};

static inline struct iovec *
iovec(const struct vbuf *vbuf)
{
	return (struct iovec *) (vbuf->iov->data);
}

inline static void
vbuf_add_unsafe(struct vbuf *vbuf, const void *buf, size_t len)
{
	struct iovec *v;
	assert(vbuf->iov->capacity - vbuf->iov->size >= sizeof(*v));
	v = vbuf->iov->data + vbuf->iov->size;
	v->iov_base = (void *)buf;
	v->iov_len = len;
	vbuf->iov->size += sizeof(*v);
	vbuf->iov_cnt++;
}

inline static void
vbuf_ensure(struct vbuf *vbuf, size_t count)
{
	tbuf_ensure(vbuf->iov, sizeof(struct iovec) * count);
}

/** Add data to the iov vector. */
inline static void
vbuf_add(struct vbuf *vbuf, const void *data, size_t len)
{
	vbuf_ensure(vbuf, 1);
	vbuf_add_unsafe(vbuf, data, len);
}

/** Duplicate data and add to the iov vector. */
inline static void
vbuf_dup(struct vbuf *vbuf, const void *data, size_t len)
{
	void *copy = palloc(vbuf->pool, len);
	memcpy(copy, data, len);
	vbuf_add(vbuf, copy, len);
}

void vbuf_setup(struct vbuf *vbuf, struct palloc_pool *pool);
void vbuf_clear(struct vbuf *vbuf, bool release);
void vbuf_flush(struct vbuf *vbuf, CoConnection *conn, bool release);

typedef void (*vbuf_cleanup_cb)(void *);
void vbuf_register_cleanup(struct vbuf *vbuf, vbuf_cleanup_cb cb, void *data);

#endif /* TARANTOOL_VBUF_H_INCLUDED */
