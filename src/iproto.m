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
#include <say.h>

const uint32_t msg_ping = 0xff00;

/* {{{ Connection Table. ******************************************/

#define CTAB_INIT_SIZE 1024

static IProtoConnection **ctab;
static int ctab_size;

/**
 * Initialize the table.
 */
static void
ctab_init(void)
{
	ctab = malloc(CTAB_INIT_SIZE * sizeof(IProtoConnection *));
	if (ctab == NULL) {
		abort();
	}
	while (ctab_size < CTAB_INIT_SIZE) {
		ctab[ctab_size++] = nil;
	}
}

/**
 * Register a connection.
 */
static void
ctab_register(IProtoConnection *conn)
{
	int n = [conn fd];
	assert(n >= 0);

	if (n >= ctab_size) {
		int sz = ctab_size;
		do {
			sz *= 2;
		} while (n >= sz);

		ctab = realloc(ctab, sz * sizeof(IProtoConnection *));
		if (ctab == NULL) {
			abort();
		}

		while (ctab_size < sz) {
			ctab[ctab_size++] = nil;
		}
	}

	assert(ctab[n] == nil);
	ctab[n] = conn;
}

/**
 * Unregister a connection.
 */
static void
ctab_unregister(IProtoConnection *conn)
{
	int n = [conn fd];
	assert(n >= 0);
	assert(n < ctab_size);
	assert(ctab[n] == conn);
	ctab[n] = nil;
}

void
ctab_close(IProtoConnection *conn)
{
	ctab_unregister(conn);
	[conn close];
	[conn free];
}

/* }}} */

/* {{{ IProto Fiber Helper. ***************************************/

@interface IProtoFiberHelper: Object <FiberPeer> {
@public
	IProtoConnection *connection;
	int pool_index;
}

@end

@implementation IProtoFiberHelper

- (const char *) peer
{
	return [connection peer];
}

- (u64) cookie
{
	return [connection cookie];
}

@end

/* }}} */

/* {{{ Worker Fiber Pool. *****************************************/

#define POOL_SIZE 1024

static struct fiber **pool;
static int pool_busy;
static int pool_size;

/**
 * Initialize the worker pool.
 */
static void
pool_init(void)
{
	pool = malloc(POOL_SIZE * sizeof(struct fiber *));
	if (pool == NULL) {
		abort();
	}
	pool_busy = 0;
	pool_size = 0;
}

static struct fiber *
pool_take_worker(void (*handler)(void *), void *data)
{
	/* Check to see if there is an idle fiber available immediately. */
	if (pool_busy == pool_size) {
		/* Check to see if the maximim pool size is reached. */
		if (pool_size == POOL_SIZE) {
			say_error("worker fibers exhauseted");
			return NULL;
		}

		/* Create a fiber helper object. */
		IProtoFiberHelper *helper = [IProtoFiberHelper new];
		if (helper == nil) {
			say_error("can't create worker helper");
			return NULL;
		}

		/* Create a fiber itself. */
		struct fiber *worker = fiber_create("worker", handler, data);
		if (worker == NULL) {
			[helper free];
			say_error("can't create worker fiber");
			return NULL;
		}

		helper->connection = nil;
		helper->pool_index = pool_size;
		worker->peer = helper;

		pool[pool_size++] = worker;
	}
	return pool[pool_busy++];
}

static void
pool_drop_worker(struct fiber *worker)
{
	IProtoFiberHelper *helper = (IProtoFiberHelper *) worker->peer;
	int index = helper->pool_index;
	assert(index >= 0);
	assert(index < pool_busy);
	assert(pool[index] == worker);

	pool_busy--;
	if (index < pool_busy) {
		helper->pool_index = pool_busy;
		helper = (IProtoFiberHelper *) pool[pool_busy]->peer;
		helper->pool_index = index;
		pool[index] = pool[pool_busy];
		pool[pool_busy] = worker;
	}
}

/* }}} */

/* {{{ Input Buffer. **********************************************/

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
 * Check to see if there is no space left in the buffer.
 */
static inline bool
inbuf_is_full(struct inbuf *inbuf)
{
	return (inbuf->start + inbuf->count) == inbuf->size;
}

static inline bool
inbuf_has_msg(struct inbuf *inbuf)
{
	/* Check if the message header is complete. */
	size_t req_len = sizeof(struct iproto_header);
	if (req_len > inbuf->count)
		return false;

	/* Check if the entire message is complete. */
	u8 *msg = inbuf->data + inbuf->start;
	req_len += ((struct iproto_header *) msg)->len;
	if (req_len > inbuf->count)
		return false;

	return true;
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
	TAILQ_ENTRY(batch) link;

	unsigned running : 1; 
	unsigned pending_input : 1;
};

/* Input queue. */
static TAILQ_HEAD(, batch) batch_running;

/* Post I/O event. */
struct ev_prepare batch_postio;

static bool
batch_input(struct batch *batch)
{
	struct inbuf *inbuf = batch->inbuf; 

again:
	if (inbuf_has_msg(inbuf)) {
		return true;
	}

	if (inbuf_is_full(inbuf)) {
		batch->pending_input = 1;
		if (inbuf_fit_msg(inbuf) == NULL) {
			/* TODO: handle out of mem properly --
			   raise client error. */
			@throw [SocketEOF new];
		}
	}

	if (batch->pending_input) {
		batch->pending_input = 0;

		iov_write(batch->conn);

		/* Find unused area offset. */
		size_t used = inbuf->start + inbuf->count;

		/* Read trying to fill all the area. */
		size_t n = [batch->conn read: inbuf->data + used :inbuf->size - used];
		inbuf->count += n;
		if (n > 0) {
			goto again;
		}
	}

	/* The data is not available yet. */
	return false;
}

static void
batch_process(void)
{
	while (!TAILQ_EMPTY(&batch_running)) {
		struct batch *batch = TAILQ_FIRST(&batch_running);
		TAILQ_REMOVE(&batch_running, batch, link);
		batch->running = 0;

		IProtoConnection *conn = batch->conn;
		IProtoService *serv = (IProtoService *) conn->service;
		assert(batch == conn->batch);

		@try {
			[conn attachWorker: fiber];
			[conn stopInput];

			if (batch->inbuf == NULL) {
				batch->inbuf = inbuf_take([serv readahead]);
				if (batch->inbuf == NULL) {
					/* TODO: handle out of mem properly --
					   raise a client error. */
					return;
				}
			}

			while (batch_input(batch)) {
				[serv process: batch];
			}

			iov_write(conn);
			fiber_gc();

			if (batch->inbuf->count == 0) {
				inbuf_drop(batch->inbuf);
				batch->inbuf = NULL;
			}

			[conn detachWorker];
			[conn startInput];
		}
		@catch (SocketEOF *) {
			iov_reset();
			[conn detachWorker];
			ctab_close(conn);
		}
		@catch (SocketError *e) {
			iov_reset();
			[conn detachWorker];
			ctab_close(conn);
			[e log];
		}
	}
	pool_drop_worker(fiber);
}

/**
 * Worker fiber handler routine.
 */
static void
batch_worker(void *dummy __attribute__((unused)))
{
	for (;;) {
		batch_process();
		fiber_yield();
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
	fprintf(stderr, "workers taken: %d, still busy: %d\n", workers, pool_busy);
}

static void
batch_init(void)
{
	ev_init(&batch_postio, (void *) batch_postio_dispatch);
	ev_prepare_start(&batch_postio);
}

static struct batch *
batch_create(void)
{
	struct batch *batch = malloc(sizeof(struct batch));
	if (unlikely(batch == NULL)) {
		return NULL;
	}

	memset(batch, 0, sizeof(struct batch));

	return batch;
}

/* }}} */

/* {{{ IProto Service. ********************************************/

@implementation IProtoService

- (id) init: (const char *)name :(struct service_config *)config
{
	self = [super init: name :config];
	if (self) {
		TAILQ_INIT(&batch_running);
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
	@try {
		ctab_register((IProtoConnection *)conn);
		[conn startInput];
	}
	@catch (id) {
		[conn close];
		[conn free];
	}
}

- (void) process: (struct batch *)batch
{
	struct inbuf *inbuf = batch->inbuf;

	struct iproto_header *msg =
		(struct iproto_header *) (inbuf->data + inbuf->start);
	size_t msg_len = sizeof(struct iproto_header) + msg->len;

	inbuf->start += msg_len;
	inbuf->count -= msg_len;

	struct iproto_header_retcode *reply =
		palloc(fiber->gc_pool, sizeof(*reply));
	reply->msg_code = msg->msg_code;
	reply->sync = msg->sync;

	if (unlikely(reply->msg_code == msg_ping)) {
		reply->len = 0;
		iov_add(reply, sizeof(struct iproto_header));
	} else {
		reply->len = sizeof(uint32_t); /* ret_code */
		iov_add(reply, sizeof(struct iproto_header_retcode));
		size_t saved_iov_cnt = fiber->iov_cnt;
		@try {
			/* make request point to iproto data */
			struct tbuf request;
			request.capacity = msg->len;
			request.size = msg->len;
			request.data = msg->data;
			request.pool = NULL;

			[self process: msg->msg_code :&request];
			reply->ret_code = 0;
		}
		@catch (ClientError *e) {
			reply->ret_code = tnt_errcode_val(e->errcode);
			fiber->iov->size -=
				(fiber->iov_cnt - saved_iov_cnt)
					* sizeof(struct iovec);
			fiber->iov_cnt = saved_iov_cnt;
			iov_dup(e->errmsg, strlen(e->errmsg) + 1);
		}
		for (; saved_iov_cnt < fiber->iov_cnt; saved_iov_cnt++) {
			reply->len += iovec(fiber->iov)[saved_iov_cnt].iov_len;
		}
	}
}

- (void) process: (uint32_t) msg_code :(struct tbuf *) request
{
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
		free(batch);
	}
	[super close];
}

- (int) fd
{
	return fd;
}

- (void) attachWorker: (struct fiber *)worker_
{
	assert(worker == NULL);
	IProtoFiberHelper *helper = (IProtoFiberHelper *) worker_->peer;
	assert(helper->connection == nil);

	worker = worker_;
	helper->connection = self;
}

- (void) detachWorker
{
	assert(worker != NULL);
	IProtoFiberHelper *helper = (IProtoFiberHelper *) worker->peer;
	assert(helper->connection == self);

	helper->connection = nil;
	worker = NULL;
}

- (void) onInput
{
	batch->pending_input = 1;
	if (!batch->running) {
		TAILQ_INSERT_TAIL(&batch_running, batch, link);
	}
}

#if 0
- (void) onOutput
{
	[(IProtoService *)service output: self];
}
#endif

@end

/* }}} */

/* {{{ Initialization. ********************************************/

void
iproto_init(void)
{
	ctab_init();
	pool_init();
	inbuf_init();
	batch_init();
}

/* }}} */
