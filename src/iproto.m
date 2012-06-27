/*
 * Copyright (C) 2010, 2011 Mail.RU
 * Copyright (C) 2010, 2011 Yuriy Vostrikov
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
#include "iproto.h"
#include "exception.h"

#include <stdio.h>
#include <string.h>

#include <errcode.h>
#include <palloc.h>
#include <fiber.h>
#include <tbuf.h>
#include <vbuf.h>
#include <say.h>

const uint32_t msg_ping = 0xff00;

/* {{{ Worker Fiber Pool. *****************************************/

static SLIST_HEAD(, fiber) pool;
//static int pool_busy;
//static int pool_size;

static void
pool_init(void)
{
	SLIST_INIT(&pool);
}

static struct fiber *
pool_take_worker(void (*handler)(void *), void *data)
{
	struct fiber *worker;

	if (!SLIST_EMPTY(&pool)) {
		worker = SLIST_FIRST(&pool);
		SLIST_REMOVE_HEAD(&pool, zombie_link);
	} else {
		/* Create a fiber itself. */
		worker = fiber_create("worker", handler, data);
		if (worker == NULL) {
			say_error("Cannot create a worker fiber");
			return NULL;
		}
	}

	worker->flags &= ~FIBER_POOLED;

	return worker;
}

static void
pool_drop_worker(struct fiber *worker)
{
	worker->flags |= FIBER_POOLED;

	SLIST_INSERT_HEAD(&pool, worker, zombie_link);
}

static void
pool_kill_worker(struct fiber *worker)
{
	if ((fiber->flags & FIBER_POOLED) != 0) {
		SLIST_REMOVE(&pool, worker, fiber, zombie_link);
	}
}

/* }}} */

/* {{{ Input Buffer. **********************************************/

enum inbuf_state {
	INBUF_PARTIAL,
	INBUF_COMPLETE,
	INBUF_OVERFLOW,
	INBUF_INVALID,
};

struct inbuf
{
	SLIST_ENTRY(inbuf) next;
	size_t start;
	size_t count;
	size_t size;
	u8 data[];
};

/* Free buffer list. */
static SLIST_HEAD(, inbuf) inbuf_dropped;

/**
 * Initialize input buffers.
 */
static void
inbuf_init(void)
{
	SLIST_INIT(&inbuf_dropped);
}

/**
 * Create an input buffer.
 */
static struct inbuf *
inbuf_create(size_t size)
{
	/* Allocate memory for the struct and data. */
	size_t total_size = size + sizeof(struct inbuf);
	struct inbuf *inbuf = malloc(total_size);
	if (unlikely(inbuf == NULL)) {
		return NULL;
	}

	/* Initialize the struct fields. */
	memset(inbuf, 0, sizeof(struct inbuf));
	inbuf->size = size;

	return inbuf;
}

#if 0
/**
 * Resize an input buffer.
 */
static struct inbuf *
inbuf_resize(struct inbuf *inbuf, size_t size)
{
	/* Allocate memory for the struct and data. */
	size_t total_size = size + sizeof(struct inbuf);
	inbuf = realloc(inbuf, total_size);
	if (unlikely(inbuf == NULL)) {
		return NULL;
	}

	/* Set the new size. */
	inbuf->size = size;

	/* Destroy affected data. */
	if (unlikely(inbuf->start > size)) {
		inbuf->start = size;
		inbuf->count = 0;
	} else if (unlikely(inbuf->start + inbuf->count > size)) {
		inbuf->count = size - inbuf->start;
	}

	return inbuf;
}
#endif

#if 0
/**
 * Split off the last data in the buffer to the next buffer.
 */
static struct inbuf *
inbuf_split(struct inbuf *inbuf, size_t size)
{
	assert(inbuf->start > 0);
	assert(inbuf->count > 0);

	/* Adjust the size to fit the data. */
	if (size < inbuf->count) {
		size = inbuf->count;
	}

	/* Allocate a buffer for carry-over data. */
	struct inbuf *split = inbuf_create(size);
	if (unlikely(split == NULL)) {
		return NULL;
	}

	/* Carry the data to the allocated buffer. */
	memcpy(split->data, inbuf->data + inbuf->start, inbuf->count);
	split->count = inbuf->count;
	inbuf->count = 0;

	return split;
}
#endif

static struct inbuf *
inbuf_recycle(struct inbuf *inbuf, size_t size)
{
	/* Move the data to the buffer start. */
	if (inbuf->start) {
		if (inbuf->count) {
			memmove(inbuf->data,
				inbuf->data + inbuf->start,
				inbuf->count);
		}
		inbuf->start = 0;
	}

	/* Resize the buffer if expanding or shrinking but
	   shrinking is only allowed for empty buffer. */
	if (size > inbuf->size
	    || (size < inbuf->size && !inbuf->count)) {
		size_t total_size = size + sizeof(struct inbuf);
		inbuf = realloc(inbuf, total_size);
		if (inbuf == NULL) {
			return NULL;
		}
		inbuf->size = size;
	}

	return inbuf;
}

/**
 * Make an input buffer empty.
 */
static inline void
inbuf_reset(struct inbuf *inbuf)
{
	inbuf->start = inbuf->count = 0;
}

/**
 * Check the state of the buffer.
 */
static inline enum inbuf_state
inbuf_check_state(struct inbuf *inbuf)
{
	/* Check if the message header is complete. */
	if (inbuf->count < sizeof(struct iproto_header)) {
		if ((inbuf->start + inbuf->count) == inbuf->size)
			return INBUF_OVERFLOW;
		return INBUF_PARTIAL;
	}

	/* Get a pointer to the header. */
	struct iproto_header *hdr =
		(struct iproto_header *) (inbuf->data + inbuf->start);

	/* Validate it. */
	if (hdr->len > IPROTO_BODY_LEN_MAX) {
		/* The message is too big, just close the connection
		   for now to avoid a possible DoS attack. */
		say_error("received package is too big: %llu",
			  (unsigned long long)hdr->len);
		return INBUF_INVALID;
	}

	/* Check if the whole message is complete. */
	if (inbuf->count < (sizeof(struct iproto_header) + hdr->len)) {
		if ((inbuf->start + inbuf->count) == inbuf->size)
			return INBUF_OVERFLOW;
		return INBUF_PARTIAL;
	}

	return INBUF_COMPLETE;
}

static struct inbuf *
inbuf_fit_msg(struct inbuf *inbuf)
{
	/* Check if the message header is complete. If not then
	   the current buffer size should be ok, it is just bad
	   header location at the buffer end. */
	size_t req_len = sizeof(struct iproto_header);
	if (req_len > inbuf->count) {
		assert(req_len < inbuf->size);
		return inbuf_recycle(inbuf, inbuf->size);
	}

	/* Check if the entire message is complete. If not then
	   the buffer size has to be expanded. */
	u8 *msg = inbuf->data + inbuf->start;
	req_len += ((struct iproto_header *) msg)->len;
	if (req_len > inbuf->count) {
		return inbuf_recycle(inbuf, req_len);
	}

	return inbuf;
}

static struct inbuf *
inbuf_take(size_t size)
{
	if (SLIST_EMPTY(&inbuf_dropped)) {
		return inbuf_create(size);
	}

	struct inbuf *inbuf = SLIST_FIRST(&inbuf_dropped);
	inbuf = inbuf_recycle(inbuf, size);
	if (inbuf != NULL) {
		SLIST_REMOVE_HEAD(&inbuf_dropped, next);
	}
	return inbuf;
}

void
inbuf_drop(struct inbuf *inbuf)
{
	inbuf_reset(inbuf);
	SLIST_INSERT_HEAD(&inbuf_dropped, inbuf, next);
}

/* }}} */

/* {{{ Input Batch. ***********************************************/

struct batch
{
	struct inbuf *inbuf;
	IProtoConnection *conn;
	struct palloc_pool *pool;
	struct vbuf outbuf;
	int outbuf_start;
	int outbuf_count;

	TAILQ_ENTRY(batch) link;

	unsigned closed : 1;
	unsigned running : 1; 
};

/* Input queue. */
static TAILQ_HEAD(, batch) batch_running;

/* Post I/O event. */
struct ev_prepare batch_postio;

static void
batch_process_msg(struct batch *batch)
{
	struct inbuf *inbuf = batch->inbuf;
	struct iproto_header *msg =
		(struct iproto_header *) (inbuf->data + inbuf->start);
	size_t msg_len = sizeof(struct iproto_header) + msg->len;
	inbuf->start += msg_len;
	inbuf->count -= msg_len;

	struct iproto_header_retcode *reply =
		palloc(batch->pool, sizeof(*reply));
	reply->msg_code = msg->msg_code;
	reply->sync = msg->sync;

	if (unlikely(reply->msg_code == msg_ping)) {
		reply->len = 0;
		vbuf_add(&batch->outbuf, reply, sizeof(struct iproto_header));
	} else {
		reply->len = sizeof(uint32_t); /* ret_code */
		vbuf_add(&batch->outbuf, reply, sizeof(struct iproto_header_retcode));
		size_t saved_iov_cnt = batch->outbuf.iov_cnt;
		@try {
			/* make request point to iproto data */
			struct tbuf request;
			request.capacity = msg->len;
			request.size = msg->len;
			request.data = msg->data;
			request.pool = NULL;

			IProtoConnection *conn = batch->conn;
			IProtoService *serv = (IProtoService *) conn->service;
			(serv->handler)(&batch->outbuf, msg->msg_code, &request);

			reply->ret_code = 0;
		}
		@catch (ClientError *e) {
			reply->ret_code = tnt_errcode_val(e->errcode);
			batch->outbuf.iov->size -=
				(batch->outbuf.iov_cnt - saved_iov_cnt)
					* sizeof(struct iovec);
			batch->outbuf.iov_cnt = saved_iov_cnt;
			vbuf_dup(&batch->outbuf, e->errmsg, strlen(e->errmsg) + 1);
		}
		for (; saved_iov_cnt < batch->outbuf.iov_cnt; saved_iov_cnt++) {
			reply->len += iovec(&batch->outbuf)[saved_iov_cnt].iov_len;
		}
	}

	batch->outbuf_count = batch->outbuf.iov_cnt - batch->outbuf_start;
}

static void
batch_process_all(void)
{
	while (!TAILQ_EMPTY(&batch_running)) {
		struct batch *batch = TAILQ_FIRST(&batch_running);
		TAILQ_REMOVE(&batch_running, batch, link);
		batch->running = 0;

		IProtoConnection *conn = batch->conn;
		assert(batch == conn->batch);
		@try {
			conn_attach_worker(conn, fiber);

			enum inbuf_state state = inbuf_check_state(batch->inbuf);
			while (state == INBUF_COMPLETE) {
				batch_process_msg(batch);
				state = inbuf_check_state(batch->inbuf);
			}

			conn_start_input(conn);
			conn_start_output(conn);
		}
		@catch (id) {
			batch->closed = 1;
			@throw;
		}
		@finally {
			conn_detach_worker(conn);

			if (batch->closed) {
				[conn close];
				[conn free];
			}
		}
	}
}

/**
 * Worker fiber handler routine.
 */
static void
batch_worker(void *dummy __attribute__((unused)))
{
	@try {
		for (;;) {
			batch_process_all();

			pool_drop_worker(fiber);

			fiber_gc();
			fiber_yield();
			fiber_testcancel();
		}
	}
	@finally {
		pool_kill_worker(fiber);
	}
}

static void
batch_input_handler(ev_io *watcher, int revents __attribute__((unused)))
{
	IProtoConnection *conn = (IProtoConnection *) watcher->data;
	struct batch *batch = conn->batch;
	struct inbuf *inbuf = batch->inbuf; 

	@try {
	again:
		switch (inbuf_check_state(inbuf)) {
		case INBUF_INVALID:
			batch->closed = 1;
			return;

		case INBUF_COMPLETE:
			conn_stop_input(conn);
			if (!batch->running) {
				TAILQ_INSERT_TAIL(&batch_running, batch, link);
				batch->running = 1;
			}
			return;

		case INBUF_PARTIAL:
			break;
		case INBUF_OVERFLOW:
			if (inbuf_fit_msg(inbuf) == NULL) {
				/* TODO: handle out of mem properly --
				   raise client error. */
				batch->closed = 1;
				return;
			}
			break;
		}

		/* Find unused area offset. */
		size_t used = inbuf->start + inbuf->count;

		/* Read trying to fill all the area. */
		size_t n = sock_read(conn->fd,
				     inbuf->data + used,
				     inbuf->size - used);

		if (n == EOF) {
			batch->closed = 1;
		} else if (n > 0) {
			inbuf->count += n;
			goto again;
		}
	}
	@catch (SocketError *e) {
		batch->closed = 1;
		[e log];
	}
	@catch (id) {
		batch->closed = 1;
		@throw;
	}
	@finally {
		if (batch->closed) {
			[conn close];
			[conn free];
		}
	}
}

static void
batch_output_handler(ev_io *watcher, int revents __attribute__((unused)))
{
	IProtoConnection *conn = (IProtoConnection *) watcher->data;
	struct batch *batch = conn->batch;
	struct vbuf *vbuf = &batch->outbuf;

	@try {
		if (batch->outbuf_count) {
			int n = sock_writev(conn->fd,
					    iovec(vbuf) + batch->outbuf_start,
					    batch->outbuf_count);
			batch->outbuf_start += n;
			batch->outbuf_count -= n;
		}
		if (batch->outbuf_start == vbuf->iov_cnt) {
			assert(batch->output_count == 0);
			batch->outbuf_start = 0;
			vbuf_clear(vbuf, true);
			vbuf_ensure(&batch->outbuf, 1024);
#if 1
			if (!batch->running && batch->inbuf->count == 0) {
				conn_stop_output(conn);
			}
#endif
		}
	}
	@catch (SocketError *e) {
		batch->closed = 1;
		[e log];
	}
	@catch (id) {
		batch->closed = 1;
		@throw;
	}
	@finally {
		if (batch->closed) {
			[conn close];
			[conn free];
		}
	}
}

static void
batch_postio_dispatch(ev_watcher *watcher __attribute__((unused)),
		      int revents __attribute__((unused)))
{
	int workers = 0;
	while (!TAILQ_EMPTY(&batch_running)) {
		struct fiber *worker = pool_take_worker(batch_worker, NULL);
		if (worker == NULL) {
			/* TODO: wait for worker availability? */
			return;
		}
		fiber_call(worker);
		workers++;
	}
//	fprintf(stderr, "workers taken: %d, still busy: %d\n", workers, pool_busy);
}

static struct batch *
batch_create(void)
{
	struct batch *batch = malloc(sizeof(struct batch));
	if (unlikely(batch == NULL)) {
		return NULL;
	}
	memset(batch, 0, sizeof(struct batch));

	batch->inbuf = inbuf_take(net_io_readahead);
	if (unlikely(batch->inbuf == NULL)) {
		free(batch);
		return NULL;
	}

	batch->pool = palloc_create_pool("");
	vbuf_setup(&batch->outbuf, batch->pool);
	vbuf_ensure(&batch->outbuf, 1024);

	return batch;
}

static void
batch_destroy(struct batch *batch)
{
	if (batch->inbuf != NULL) {
		inbuf_drop(batch->inbuf);
	}
	if (batch->pool != NULL) {
		palloc_destroy_pool(batch->pool);
	}
	free(batch);
}

static void
batch_init(void)
{
	TAILQ_INIT(&batch_running);

	ev_init(&batch_postio, (void *) batch_postio_dispatch);
	ev_prepare_start(&batch_postio);
}

/* }}} */

/* {{{ IProto Service. ********************************************/

@implementation IProtoService

- (id) init: (const char *)name
	   :(struct service_config *)config
	   :(iproto_handler)handler_arg;
{
	self = [super init: name :config];
	if (self) {
		handler = handler_arg;
	}
	return self;
}

- (Connection *) allocConnection
{
	IProtoConnection *conn = [IProtoConnection alloc];
	if (conn != nil) {
		conn->batch = batch_create();
		if (conn->batch == NULL) {
			[conn free];
			return nil;
		}
		conn->batch->conn = conn;
	}
	return conn;
}

- (void) onConnect: (ServiceConnection *)conn
{
	conn_start_input(conn);
}

- (io_handler) getInputHandler
{
	return batch_input_handler;
}

- (io_handler) getOutputHandler
{
	return batch_output_handler;
}

- (void) process: (struct vbuf *)wbuf
		:(uint32_t)msg_code
		:(struct tbuf *)request
{
	(void) wbuf;
	(void) msg_code;
	(void) request;
	[self subclassResponsibility: _cmd];
}

@end

/* }}} */

/* {{{ IProto Connection. *****************************************/

@implementation IProtoConnection

- (void) close
{
	if (batch != NULL) {
		if (batch->running) {
			TAILQ_REMOVE(&batch_running, batch, link);
		}
		batch_destroy(batch);
	}
	[super close];
}

@end

/* }}} */

/* {{{ Initialization. ********************************************/

void
iproto_init(void)
{
	pool_init();
	inbuf_init();
	batch_init();
}

/* }}} */
