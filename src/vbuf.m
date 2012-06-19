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

#include <vbuf.h>
#include <net_io.h>

struct vbuf_cleanup
{
	vbuf_cleanup_cb cb;
	void *data;
};

/**
 * Initialize a new iov vector buffer.
 */
void
vbuf_setup(struct vbuf *vbuf, struct palloc_pool *pool)
{
	vbuf->pool = pool;
	vbuf->iov = tbuf_alloc(vbuf->pool);
	vbuf->cleanup = tbuf_alloc(vbuf->pool);
	vbuf->iov_cnt = 0;
}

/**
 * Register a cleanup callbacks.
 */
void
vbuf_register_cleanup(struct vbuf *vbuf, vbuf_cleanup_cb cb, void *data)
{
	struct vbuf_cleanup vc = { .cb = cb, .data = data };
	tbuf_append(vbuf->cleanup, &vc, sizeof(vc));
}

/**
 * Clear the iov vector invoking the registered cleanup callbacks.
 */
void
vbuf_clear(struct vbuf *vbuf, bool release)
{
	/* Invoke the callbacks. */
	struct vbuf_cleanup *cleanup = vbuf->cleanup->data;
	int i = vbuf->cleanup->size / sizeof(struct vbuf_cleanup);
	while (i-- > 0) {
		cleanup->cb(cleanup->data);
		cleanup++;
	}

	/* Clear the buffers. */
	if (release) {
		prelease(vbuf->pool);
		vbuf->iov = tbuf_alloc(vbuf->pool);
		vbuf->cleanup = tbuf_alloc(vbuf->pool);
	} else {
		tbuf_reset(vbuf->iov);
		tbuf_reset(vbuf->cleanup);
	}
	vbuf->iov_cnt = 0;
}

/**
 * Write the iov vector to the connection. Clear it after writing.
 */
void
vbuf_flush(struct vbuf *vbuf, CoConnection *conn, bool release)
{
	@try {
		struct iovec *iov = iovec(vbuf);
		[conn coWriteV: iov :vbuf->iov_cnt];
	}
	@finally {
		vbuf_clear(vbuf, release);
	}
}
