#ifndef TARANTOOL_FIBER_H_INCLUDED
#define TARANTOOL_FIBER_H_INCLUDED
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

#include "config.h"

#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>
#include <netinet/in.h>

#include <tarantool_ev.h>
#include <tbuf.h>
#include <iov_buf.h>
#include <coro.h>
#include <util.h>
#include "third_party/queue.h"

#include "exception.h"
#include "palloc.h"

#define FIBER_NAME_MAXLEN 32

/* The fiber is in the pool. */
#define FIBER_POOLED	    0x1
/** Can this fiber be cancelled? */
#define FIBER_CANCELLABLE   0x2
/** Indicates that a fiber has been cancelled. */
#define FIBER_CANCEL        0x4

/** This is thrown by fiber_* API calls when the fiber is
 * cancelled.
 */

@interface FiberCancelException: tnt_Exception
@end

@protocol FiberPeer
- (const char *) peer;
- (u64) cookie;
@end

struct fiber {
	ev_async async;
#ifdef ENABLE_BACKTRACE
	void *last_stack_frame;
#endif
	int csw;
	struct tarantool_coro coro;
	/* A garbage-collected memory pool. */
	struct palloc_pool *gc_pool;
	uint32_t fid;

	ev_timer timer;
	ev_child cw;

	struct tbuf *rbuf;

	SLIST_ENTRY(fiber) link, zombie_link;

	/* ASCIIZ name of this fiber. */
	char name[FIBER_NAME_MAXLEN];
	void (*f) (void *);
	void *f_data;
	u32 flags;

	id<FiberPeer> peer;

	struct fiber *waiter;
};

SLIST_HEAD(, fiber) fibers, zombie_fibers;

extern struct fiber *fiber;

void fiber_init(void);
void fiber_free(void);
struct fiber *fiber_create(const char *name, void (*f) (void *), void *);
void fiber_set_name(struct fiber *fiber, const char *name);
void wait_for_child(pid_t pid);

void fiber_io_wait(int fd, int events);

void
fiber_yield(void);

void
fiber_yield_to(struct fiber *f);

void fiber_destroy_all();

const char *fiber_peer_name(struct fiber *fiber);
u64 fiber_peer_cookie(struct fiber *fiber);

bool fiber_gc(void);
void fiber_call(struct fiber *callee);
void fiber_wakeup(struct fiber *f);
struct fiber *fiber_find(int fid);
/** Cancel a fiber. A cancelled fiber will have
 * tnt_FiberCancelException raised in it.
 *
 * A fiber can be cancelled only if it is
 * FIBER_CANCELLABLE flag is set.
 */
void fiber_cancel(struct fiber *f);
/** Check if the current fiber has been cancelled.  Raises
 * tnt_FiberCancelException
 */
void fiber_testcancel(void);
/** Make it possible or not possible to cancel the current
 * fiber.
 */
void fiber_setcancelstate(bool enable);
void fiber_sleep(ev_tstamp s);
void fiber_info(struct tbuf *out);
int set_nonblock(int sock);

#endif /* TARANTOOL_FIBER_H_INCLUDED */
