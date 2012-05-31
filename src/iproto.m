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

/* {{{ Input Buffer. **********************************************/

struct inbuf
{
	size_t start;
	size_t count;
	struct inbuf *next;
	size_t size;
	u8 data[];
};

/**
 * Make an input buffer empty.
 */
static inline void
inbuf_reset(struct inbuf *inbuf)
{
	inbuf->start = inbuf->count = 0;
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
	inbuf->start = 0;
	inbuf->count = 0;
	inbuf->next = NULL;
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
	assert(inbuf->next == NULL);

	/* Adjust the size to fit the data. */
	if (size < inbuf->count) {
		size = inbuf->count;
	}

	/* Allocate a buffer for carry-over data. */
	inbuf->next = inbuf_create(size);
	if (unlikely(inbuf->next == NULL)) {
		return NULL;
	}

	/* Carry the data to the allocated buffer. */
	memcpy(inbuf->next->data, inbuf->data + inbuf->start, inbuf->count);
	inbuf->next->count = inbuf->count;
	inbuf->count = 0;

	/* Adjust the old buffer. */
	return inbuf_resize(inbuf, inbuf->start);
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

static size_t
inbuf_read(struct inbuf *inbuf, IProtoConnection *conn)
{
	/* Find unused area offset. */
	size_t off = inbuf->start + inbuf->count;
	/* Read trying to fill the area. */
	size_t n = [conn read: inbuf->data + off :inbuf->size - off];
	inbuf->count += n;
	return n;
}

/* }}} */

/* {{{ Input Batch. ***********************************************/

struct batch
{
	IProtoConnection *conn;
	struct inbuf *data;
	struct inbuf *tail;
	struct batch *next;
};

#if 0
static struct batch *
batch_create(IProtoConnection *conn)
{
	struct batch *batch = malloc(sizeof(struct batch));
	if (batch == NULL) {
		return NULL;
	}

	batch->conn = conn;
	batch->data = NULL;
	batch->tail = NULL;
	batch->next = NULL;

	return batch;
}

static void
batch_handle(struct batch *batch)
{
}
#endif

/* }}} */

/* {{{ IProto Service. ********************************************/

#define CTAB_SIZE 1024
#define POOL_SIZE 1024

/**
 * IProto fiber handler.
 */
static void
iproto_loop(IProtoService *service)
{
	for (;;) {
		fprintf(stderr, "iproto loop cycle\n");
		[service process];
		fprintf(stderr, "iproto loop yield\n");
		fiber_yield();
	}
}

@implementation IProtoService

- (id) init: (const char *)name :(struct service_config *)config
{
	self = [super init: name :config];
	if (self) {
		ctab = malloc(CTAB_SIZE * sizeof(IProtoConnection *));
		if (ctab == NULL) {
			abort();
		}
		while (ctab_size < CTAB_SIZE) {
			ctab[ctab_size++] = nil;
		}

		pool = malloc(POOL_SIZE * sizeof(struct fiber *));
		if (pool == NULL) {
			abort();
		}
		pool_busy = 0;
		pool_idle = 0;

		standby_worker = NULL;

		inbuf = NULL;

		ev_init_postio_handler(&post, self);
	}
	return self;
}

- (Connection *) allocConnection
{
	return [IProtoConnection alloc];
}

- (void) registerConnection: (IProtoConnection *)conn
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

- (void) unregisterConnection: (IProtoConnection *)conn
{
	int n = [conn fd];
	assert(n >= 0);
	assert(n < ctab_size);
	assert(ctab[n] == conn);
	ctab[n] = nil;
}

- (void) onConnect: (ServiceConnection *)conn
{
	@try {
		[self registerConnection: (IProtoConnection *)conn];
		[conn startInput];
	}
	@catch (id) {
		[conn close];
		[conn free];
	}
}

- (struct fiber *) makeWorker
{
	int index = pool_busy + pool_idle;
	if (index == POOL_SIZE) {
		say_error("worker fibers exhauseted");
		return NULL;
	}

	IProtoFiberHelper *helper = [IProtoFiberHelper new];
	if (helper == nil) {
		say_error("can't create worker helper");
		return NULL;
	}

	helper->connection = nil;
	helper->pool_index = index;

	struct fiber *worker = fiber_create("worker",
					    (void (*)(void *)) iproto_loop,
					    self);
	if (worker == NULL) {
		say_error("can't create worker fiber");
		[helper free];
		return NULL;
	}

	worker->peer = helper;
	pool[index] = worker;
	pool_idle++;

	return worker;
}

- (struct fiber *) takeWorker
{
	struct fiber *worker;
	if (pool_idle) {
		worker = pool[pool_busy];
	} else {
		worker = [self makeWorker];
		if (worker == NULL) {
			return NULL;
		}
		assert(pool_idle == 1);
	}
	pool_busy++;
	pool_idle--;
	return worker;
}

- (void) dropWorker: (struct fiber *)worker
{
	IProtoFiberHelper *helper = (IProtoFiberHelper *) worker->peer;
	int index = helper->pool_index;
	assert(index >= 0);
	assert(index < pool_busy);
	assert(pool[index] == worker);

	pool_busy--;
	pool_idle++;
	if (index < pool_busy) {
		helper->pool_index = pool_busy;
		helper = (IProtoFiberHelper *) pool[pool_busy]->peer;
		helper->pool_index = index;
		pool[index] = pool[pool_busy];
		pool[pool_busy] = worker;
	}
}

- (struct fiber *) findWorker
{
	struct fiber *worker;
	if (standby_worker == NULL) {
		worker = [self takeWorker];
	} else {
		worker = standby_worker;
		standby_worker = NULL;
	}
	return worker;
}

- (void) freeWorker: (struct fiber *)worker
{
	if (standby_worker != NULL) {
		[self dropWorker: standby_worker];
	}
	standby_worker = worker;
}

- (void) grabInputBuffer: (IProtoConnection *)conn
{
	if (conn->inbuf == NULL) {
		/* There is no bound buffer. */
		if (inbuf == NULL) {
			/* There is no cached free buffer. */
			inbuf = inbuf_create([self readahead]);
		}
	} else {
		/* There is bound buffer. */
		if (inbuf != NULL) {
			/* There is cached free buffer. */
			free(inbuf);
		}
		inbuf = inbuf_recycle(conn->inbuf,
						    [self readahead]);
		conn->inbuf = NULL;
	}
}

- (void) bindInputBuffer: (IProtoConnection *)conn
{
	assert(conn->inbuf == NULL);
	if (inbuf->count) {
		conn->inbuf = inbuf;
		inbuf = NULL;
	}
}

- (void) process
{
	fprintf(stderr, "IProtoService process\n");

	IProtoFiberHelper *helper = (IProtoFiberHelper *) fiber->peer;
	assert(helper->pool_index >= 0);
	assert(helper->pool_index < pool_busy);
	assert(pool[helper->pool_index] == fiber);
	IProtoConnection *conn = helper->connection; 

	@try {

		[conn stopInput];
		fiber->flags &= ~FIBER_READY;

		struct iproto_header *msg =
			(struct iproto_header *)(inbuf->data + inbuf->start);
		size_t msg_len = sizeof(struct iproto_header) + msg->len;

		fprintf(stderr, "msg: (%d) '", (int) msg_len);
		for (int j = 0; j < msg_len; j++) {
			unsigned c = *(inbuf->data + inbuf->start + j);
			if (c == '\\')
				fprintf(stderr, "\\\\");
			else if (c >= 32 && c < 127)
				fprintf(stderr, "%c", c);
			else
				fprintf(stderr, "\\%02x", c);
		}
		fprintf(stderr, "'\n");

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
				fiber->iov->size -= (fiber->iov_cnt - saved_iov_cnt) * sizeof(struct iovec);
				fiber->iov_cnt = saved_iov_cnt;
				iov_dup(e->errmsg, strlen(e->errmsg) + 1);
			}
			for (; saved_iov_cnt < fiber->iov_cnt; saved_iov_cnt++) {
				reply->len += iovec(fiber->iov)[saved_iov_cnt].iov_len;
			}
		}

		iov_write(conn);
		fiber_gc();

		[conn startInput];
		[conn detachWorker];
	}
	@catch (SocketEOF *) {
		[conn detachWorker];
		[self unregisterConnection: conn];
		[conn close];
		[conn free];
	}
	@catch (SocketError *e) {
		[conn detachWorker];
		[self unregisterConnection: conn];
		[conn close];
		[conn free];
		[e log];
	}
	@finally {
		fiber->flags |= FIBER_READY;
		[self freeWorker: fiber];
	}
}

- (void) dispatchInput: (IProtoConnection *)conn
{
	fprintf(stderr, "IProtoService dispatchInput\n");

	for (;;) {
		/* Read the data. */
		size_t n = inbuf_read(inbuf, conn);
		if (n == 0) {
			return;
		}

		/* Handle all complete messages in the buffer. */
		while (inbuf_has_msg(inbuf)) {
			struct fiber *worker = [self findWorker];
			if (worker == NULL) {
				/* TODO: wait for worker availability? */
				@throw [SocketEOF new];
			}
			[conn attachWorker: worker];

			fiber_call(worker);
			fprintf(stderr, "fiber input back\n");

			if ((worker->flags & FIBER_READY) == 0) {
				/* Processing is not completed. */
				fprintf(stderr, "fiber is not ready\n");
				return;
			}
		}
		fprintf(stderr, "fiber has no msg\n");

		/* The data must not be available yet. */
		if (!inbuf_is_full(inbuf)) {
			fprintf(stderr, "fiber is not full\n");
			return;
		}

		/* Otherwise the read was incomplete because there was no
		   enough space in the buffer. Extend it and repeat. */
		if (inbuf_fit_msg(inbuf) == NULL) {
			/* TODO: handle out of mem properly --
			   raise client error. */
			@throw [SocketEOF new];
		}
	}
}

- (void) input: (IProtoConnection *)conn
{
	fprintf(stderr, "IProtoService input\n");
	@try {
		[self grabInputBuffer: conn];
		[self dispatchInput: conn];
		[self bindInputBuffer: conn];
	}
	@catch (SocketEOF *) {
		[self unregisterConnection: conn];
		[conn close];
		[conn free];
	}
	@catch (SocketError *e) {
		[self unregisterConnection: conn];
		[conn close];
		[conn free];
		[e log];
	}
	@finally {
		if (inbuf != NULL) {
			inbuf_reset(inbuf);
		}
	}
}

- (void) output: (IProtoConnection *)conn
{
	@try {
	}
	@catch (SocketEOF *) {
		[self unregisterConnection: conn];
		[conn close];
		[conn free];
	}
	@catch (SocketError *e) {
		[self unregisterConnection: conn];
		[conn close];
		[conn free];
		[e log];
	}
}

- (void) postIO
{
	struct batch **bpp = &batch;
	for (;;) {
		struct batch *bp = *bpp;
		if (bp == NULL) {
			break;
		}
		bpp = &bp->next;
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

- (id) init: (Service *)service_ :(int)fd_
{
	self = [super init: service_ :fd_];
	if (self) {
		inbuf = NULL;
	}
	return self;
}

- (void) close
{
	if (inbuf != NULL) {
		free(inbuf);
		inbuf = NULL;
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
	[(IProtoService *)service input: self];
}

#if 0
- (void) onOutput
{
	[(IProtoService *)service output: self];
}
#endif

@end

/* }}} */
