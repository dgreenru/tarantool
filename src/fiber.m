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

#include "fiber.h"
#include "config.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/types.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <unistd.h>
#include <third_party/queue.h>
#include <assoc.h>

#include <palloc.h>
#include <salloc.h>
#include <say.h>
#include <tarantool.h>
#include TARANTOOL_CONFIG
#include <tarantool_ev.h>
#include <tbuf.h>
#include <util.h>
#include <stat.h>
#include <pickle.h>
#include <net_io.h>

@implementation FiberCancelException
@end

#define FIBER_CALL_STACK 16

static struct fiber sched;
struct fiber *fiber = &sched;
static struct fiber **sp, *call_stack[FIBER_CALL_STACK];
static uint32_t last_used_fid;
static struct palloc_pool *ex_pool;

static struct mh_i32ptr_t *fibers_registry;

static void
update_last_stack_frame(struct fiber *fiber)
{
#ifdef ENABLE_BACKTRACE
	fiber->last_stack_frame = __builtin_frame_address(0);
#else
	(void)fiber;
#endif /* ENABLE_BACKTRACE */
}

void
fiber_call(struct fiber *callee)
{
	struct fiber *caller = fiber;

	assert(sp - call_stack < FIBER_CALL_STACK);
	assert(caller);

	fiber = callee;
	*sp++ = caller;

	update_last_stack_frame(caller);

	callee->csw++;
	coro_transfer(&caller->coro.ctx, &callee->coro.ctx);
}


/** Interrupt a synchronous wait of a fiber inside the event loop.
 * We do so by keeping an "async" event in every fiber, solely
 * for this purpose, and raising this event here.
 */

void
fiber_wakeup(struct fiber *f)
{
	ev_async_send(&f->async);
}

/** Cancel the subject fiber.
 *
 * Note: this is not guaranteed to succeed, and requires a level
 * of cooperation on behalf of the fiber. A fiber may opt to set
 * FIBER_CANCELLABLE to false, and never test that it was
 * cancelled.  Such fiber we won't be ever to cancel, ever, and
 * for such fiber this call will lead to an infinite wait.
 * However, fiber_testcancel() is embedded to the rest of fiber_*
 * API (@sa fiber_yield()), which makes most of the fibers that opt in,
 * cancellable.
 *
 * Currently cancellation can only be synchronous: this call
 * returns only when the subject fiber has terminated.
 *
 * The fiber which is cancelled, has FiberCancelException raised
 * in it. For cancellation to work, this exception type should be
 * re-raised whenever (if) it is caught.
 */

void
fiber_cancel(struct fiber *f)
{
	assert(f->fid != 0);
	assert(!(f->flags & FIBER_CANCEL));

	f->flags |= FIBER_CANCEL;

	if (f == fiber) {
		fiber_testcancel();
		return;
	}
	/**
	 * In most cases the fiber is CANCELLABLE and
	 * will notice it's been cancelled right away.
	 * So we just invoke it here in hope it'll die
	 * and yield to us without a full scheduler loop.
	 */
	fiber_call(f);

	if (f->fid) {
		/*
		 * Syncrhonous cancel did not work: apparently
		 * the fiber is not CANCELLABLE or for some reason
		 * chose to yield without dying. We have no
		 * choice but to wait asynchronously.
		 */
		assert(f->waiter == NULL);
		f->waiter = fiber;
		fiber_yield();
	}
	/*
	 * Here we can't even check f->fid is 0 since
	 * f could have already been reused. Knowing
	 * at least that we can't get scheduled ourselves
	 * unless asynchronously woken up is somewhat a relief.
	 */

	fiber_testcancel(); /* Check if we're ourselves cancelled. */
}

static bool
fiber_is_cancelled()
{
	return (fiber->flags & FIBER_CANCELLABLE &&
		fiber->flags & FIBER_CANCEL);
}

/** Test if this fiber is in a cancellable state and was indeed
 * cancelled, and raise an exception (FiberCancelException) if
 * that's the case.
 */

void
fiber_testcancel(void)
{
	if (fiber_is_cancelled())
		tnt_raise(FiberCancelException);
}



/** Change the current cancellation state of a fiber. This is not
 * a cancellation point.
 */

void fiber_setcancelstate(bool enable)
{
	if (enable == true)
		fiber->flags |= FIBER_CANCELLABLE;
	else
		fiber->flags &= ~FIBER_CANCELLABLE;
}

/**
 * @note: this is not a cancellation point (@sa fiber_testcancel())
 * but it is considered good practice to call testcancel()
 * after each yield.
 */

void
fiber_yield(void)
{
	struct fiber *callee = *(--sp);
	struct fiber *caller = fiber;

	fiber = callee;
	update_last_stack_frame(caller);

	callee->csw++;
	coro_transfer(&caller->coro.ctx, &callee->coro.ctx);
}

void
fiber_yield_to(struct fiber *f)
{
	fiber_wakeup(f);
	fiber_yield();
	fiber_testcancel();
}

/**
 * @note: this is a cancellation point (@sa fiber_testcancel())
 */

void
fiber_sleep(ev_tstamp delay)
{
	ev_timer_set(&fiber->timer, delay, 0.);
	ev_timer_start(&fiber->timer);
	fiber_yield();
	ev_timer_stop(&fiber->timer);
	fiber_testcancel();
}

/** Wait for a forked child to complete.
 * @note: this is a cancellation point (@sa fiber_testcancel()).
*/

void
wait_for_child(pid_t pid)
{
	ev_child_set(&fiber->cw, pid, 0);
	ev_child_start(&fiber->cw);
	fiber_yield();
	ev_child_stop(&fiber->cw);
	fiber_testcancel();
}

static void
ev_schedule(ev_watcher *watcher, int event __attribute__((unused)))
{
	assert(fiber == &sched);
	fiber_call(watcher->data);
}

void
fiber_io_wait(int fd, int events)
{
	ev_io io;
	ev_io_init(&io, (void *)ev_schedule, fd, events);
	io.data = fiber;
	ev_io_start(&io);
	fiber_yield();
	ev_io_stop(&io);
	fiber_testcancel();
}

struct fiber *
fiber_find(int fid)
{
	mh_int_t k = mh_i32ptr_get(fibers_registry, fid);

	if (k == mh_end(fibers_registry))
		return NULL;
	if (!mh_exist(fibers_registry, k))
		return NULL;
	return mh_value(fibers_registry, k);
}

static void
register_fid(struct fiber *fiber)
{
	int ret;
	mh_i32ptr_put(fibers_registry, fiber->fid, fiber, &ret);
}

static void
unregister_fid(struct fiber *fiber)
{
	mh_int_t k = mh_i32ptr_get(fibers_registry, fiber->fid);
	mh_i32ptr_del(fibers_registry, k);
}

static void
fiber_alloc(struct fiber *fiber)
{
	prelease(fiber->gc_pool);
	fiber->rbuf = tbuf_alloc(fiber->gc_pool);
}

bool
fiber_gc(void)
{
	if (palloc_allocated(fiber->gc_pool) < 128 * 1024)
		return false;

	struct palloc_pool *tmp = fiber->gc_pool;
	fiber->gc_pool = ex_pool;
	ex_pool = tmp;
	palloc_set_name(fiber->gc_pool, fiber->name);
	palloc_set_name(ex_pool, "ex_pool");
	fiber->rbuf = tbuf_clone(fiber->gc_pool, fiber->rbuf);

	prelease(ex_pool);
	return true;
}


/** Destroy the currently active fiber and prepare it for reuse.
 */

static void
fiber_zombificate()
{
	if (fiber->waiter)
		fiber_wakeup(fiber->waiter);
	fiber->waiter = NULL;
	fiber_set_name(fiber, "zombie");
	fiber->f = NULL;
	unregister_fid(fiber);
	fiber->fid = 0;
	fiber->flags = 0;
	fiber_alloc(fiber);

	SLIST_INSERT_HEAD(&zombie_fibers, fiber, zombie_link);
}

static void
fiber_loop(void *data __attribute__((unused)))
{
	for (;;) {
		assert(fiber != NULL && fiber->f != NULL && fiber->fid != 0);
		@try {
			fiber->f(fiber->f_data);
		}
		@catch (FiberCancelException *e) {
			say_info("fiber `%s' has been cancelled", fiber->name);
			say_info("fiber `%s': exiting", fiber->name);
		}
		@catch (id e) {
			say_error("fiber `%s': exception `%s'", fiber->name, object_getClassName(e));
			panic("fiber `%s': exiting", fiber->name);
		}
		fiber_zombificate();
		fiber_yield();	/* give control back to scheduler */
	}
}

/** Set fiber name.
 *
 * @param[in] name the new name of the fiber. Truncated to
 * FIBER_NAME_MAXLEN.
*/

void
fiber_set_name(struct fiber *fiber, const char *name)
{
	assert(name != NULL);
	snprintf(fiber->name, sizeof(fiber->name), "%s", name);
}

/* fiber never dies, just become zombie */
struct fiber *
fiber_create(const char *name, void (*f) (void *), void *f_data)
{
	struct fiber *fiber = NULL;

	if (!SLIST_EMPTY(&zombie_fibers)) {
		fiber = SLIST_FIRST(&zombie_fibers);
		SLIST_REMOVE_HEAD(&zombie_fibers, zombie_link);
	} else {
		fiber = palloc(eter_pool, sizeof(*fiber));
		if (fiber == NULL)
			return NULL;

		memset(fiber, 0, sizeof(*fiber));
		if (tarantool_coro_create(&fiber->coro, fiber_loop, NULL) == NULL)
			return NULL;

		fiber->gc_pool = palloc_create_pool("");

		fiber_alloc(fiber);
		ev_async_init(&fiber->async, (void *)ev_schedule);
		ev_async_start(&fiber->async);
		ev_init(&fiber->timer, (void *)ev_schedule);
		ev_init(&fiber->cw, (void *)ev_schedule);
		fiber->async.data = fiber->timer.data = fiber->cw.data = fiber;

		SLIST_INSERT_HEAD(&fibers, fiber, link);
	}

	fiber->f = f;
	fiber->f_data = f_data;
	while (++last_used_fid <= 100) ;	/* fids from 0 to 100 are reserved */
	fiber->fid = last_used_fid;
	fiber->flags = 0;
	fiber->peer = nil;
	fiber->waiter = NULL;
	fiber_set_name(fiber, name);
	palloc_set_name(fiber->gc_pool, fiber->name);
	register_fid(fiber);

	return fiber;
}

/*
 * note, we can't release memory allocated via palloc(eter_pool, ...)
 * so, struct fiber and some of its members are leaked forever
 */

void
fiber_destroy(struct fiber *f)
{
	if (f == fiber) /* do not destroy running fiber */
		return;
	if (strcmp(f->name, "sched") == 0)
		return;

	ev_async_stop(&f->async);
	palloc_destroy_pool(f->gc_pool);
	tarantool_coro_destroy(&f->coro);
}

void
fiber_destroy_all()
{
	struct fiber *f;
	SLIST_FOREACH(f, &fibers, link)
		fiber_destroy(f);
}


const char *
fiber_peer_name(struct fiber *fiber)
{
	return fiber->peer == nil ? NULL : [fiber->peer peer];
}

u64
fiber_peer_cookie(struct fiber *fiber)
{
	return fiber->peer == nil ? 0 : [fiber->peer cookie];
}

int
set_nonblock(int sock)
{
	int flags;
	if ((flags = fcntl(sock, F_GETFL, 0)) < 0 || fcntl(sock, F_SETFL, flags | O_NONBLOCK) < 0)
		return -1;
	return sock;
}

void
fiber_info(struct tbuf *out)
{
	struct fiber *fiber;

	tbuf_printf(out, "fibers:" CRLF);
	SLIST_FOREACH(fiber, &fibers, link) {
		void *stack_top = fiber->coro.stack + fiber->coro.stack_size;

		tbuf_printf(out, "  - fid: %4i" CRLF, fiber->fid);
		tbuf_printf(out, "    csw: %i" CRLF, fiber->csw);
		tbuf_printf(out, "    name: %s" CRLF, fiber->name);
		tbuf_printf(out, "    peer: %s" CRLF, fiber_peer_name(fiber));
		tbuf_printf(out, "    stack: %p" CRLF, stack_top);
#ifdef ENABLE_BACKTRACE
		tbuf_printf(out, "    backtrace:" CRLF "%s",
			    backtrace(fiber->last_stack_frame,
				      fiber->coro.stack, fiber->coro.stack_size));
#endif /* ENABLE_BACKTRACE */
	}
}

void
fiber_init(void)
{
	SLIST_INIT(&fibers);
	fibers_registry = mh_i32ptr_init();

	ex_pool = palloc_create_pool("ex_pool");

	memset(&sched, 0, sizeof(sched));
	sched.fid = 1;
	fiber_set_name(&sched, "sched");
	sched.gc_pool = palloc_create_pool(sched.name);

	sp = call_stack;
	fiber = &sched;
	last_used_fid = 100;
}

void
fiber_free(void)
{
	/* Only clean up if initialized. */
	if (fibers_registry) {
		fiber_destroy_all();
		mh_i32ptr_destroy(fibers_registry);
	}
}
