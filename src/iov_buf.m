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

#include <iov_buf.h>
#include <net_io.h>

struct iov_cleanup
{
	iov_cleanup_cb cb;
	void *cb_arg;
};

/**
 * Initialize a new iov vector buffer.
 */
void
iov_setup(struct iov_buf *vbuf, struct palloc_pool *pool)
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
iov_register_cleanup(struct iov_buf *vbuf, iov_cleanup_cb cb, void *cb_arg)
{
	struct iov_cleanup vc = { .cb = cb, .cb_arg = cb_arg };
	tbuf_append(vbuf->cleanup, &vc, sizeof(vc));
}

/**
 * Clear the iov vector invoking the registered cleanup callbacks.
 */
void
iov_clear(struct iov_buf *vbuf, bool release)
{
	/* Invoke the callbacks. */
	struct iov_cleanup *cleanup = vbuf->cleanup->data;
	int i = vbuf->cleanup->size / sizeof(struct iov_cleanup);
	while (i-- > 0) {
		cleanup->cb(cleanup->cb_arg);
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
iov_flush(struct iov_buf *vbuf, CoConnection *conn, bool release)
{
	@try {
		struct iovec *iov = iovec(vbuf);
		[conn coWriteV: iov :vbuf->iov_cnt];
	}
	@finally {
		iov_clear(vbuf, release);
	}
}
