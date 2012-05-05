/*
 * Copyright (C) 2012 Mail.RU
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

#include <net_io.h>
#include <sock.h>

/* {{{ Event Handlers. ********************************************/

static void
timer_cb(ev_watcher *watcher, int revents __attribute__((unused)))
{
	id <TimerHandler> handler = watcher->data;
	[handler onTimer];
}

static void
input_cb(ev_watcher *watcher, int revents __attribute__((unused)))
{
	id <InputHandler> handler = watcher->data;
	[handler onInput];
}

static void
output_cb(ev_watcher *watcher, int revents __attribute__((unused)))
{
	id <OutputHandler> handler = watcher->data;
	[handler onOutput];
}

void
ev_init_timer_handler(ev_timer *watcher, id<TimerHandler> handler)
{
	watcher->data = handler;
	ev_init(watcher, (void *) timer_cb);
}

void
ev_init_input_handler(ev_io *watcher, id<InputHandler> handler)
{
	watcher->data = handler;
	ev_init(watcher, (void *) input_cb);
}

void
ev_init_output_handler(ev_io *watcher, id<OutputHandler> handler)
{
	watcher->data = handler;
	ev_init(watcher, (void *) output_cb);
}

/* }}} */

/* {{{ Abstract Service and Connection. ***************************/

@implementation Connection

- (id) init
{
	self = [super init];
	if (self) {
		fd = -1;
	}
	return self;
}

- (void) open: (Service *)service_ :(int)fd_
{
	assert(fd == -1);
	assert(fd_ >= 0);

	service = service_;
	fd = fd_;

	ev_init_input_handler(&input, self);
	ev_io_set(&input, fd, EV_READ);

	ev_init_output_handler(&output, self);
	ev_io_set(&output, fd, EV_WRITE);
}

- (void) close
{
	assert(fd >= 0);

	[self stopInput];
	[self stopOutput];

	close(fd);
	fd = -1;
}

- (void) startInput
{
	ev_io_start(&input);
}

- (void) stopInput
{
	ev_io_stop(&input);
}

- (void) startOutput
{
	ev_io_start(&output);
}

- (void) stopOutput
{
	ev_io_stop(&output);
}

- (size_t) read: (void *)buf :(size_t)count
{
	assert(fd >= 0);
	fprintf(stderr, "read\n");
	return sock_read(fd, buf, count);
}

- (size_t) write: (void *)buf :(size_t)count
{
	assert(fd >= 0);
	fprintf(stderr, "write\n");
	return sock_write(fd, buf, count);
}

- (void) coRead: (void *)buf :(size_t)count
{
	[self startInput];
	@try {
		for (;;) {
			/* Read as much data as possible. */
			size_t n = [self read: buf :count];
			if (n == count) {
				break;
			}

			/* Go past the data just read. */
			buf += n;
			count -= n;

			/* Yield control to other fibers. */
			fiber_yield();
			fiber_testcancel();
		}
	}
	@finally {
		[self stopInput];
	}
}

- (int) coRead: (void *)buf :(size_t)min_count :(size_t)max_count
{
	assert(min_count <= max_count);
	[self startInput];
	@try {
		size_t total = 0;
		for (;;) {
			/* Read as much data as possible. */
			size_t n = [self read: buf :max_count];
			if ((total += n) >= min_count) {
				break;
			}

			/* Go past the data just read. */
			buf += n;
			max_count -= n;

			/* Yield control to other fibers. */
			fiber_yield();
			fiber_testcancel();
		}
		return total;
	}
	@finally {
		[self stopInput];
	}
}

- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count
{
	size_t max_count = MAX(min_count, [service getReadAhead]);
	tbuf_ensure(buf, max_count);
	buf->size += [self coRead: buf->data + buf->size :min_count :max_count];
}

- (void) coWrite: (void *)buf :(size_t)count
{
	[self startOutput];
	@try {
		for (;;) {
			/* Write as much data as possible. */
			size_t n = [self write: buf :count];
			if (n == count) {
				break;
			}

			/* Go past the data just written. */
			buf += n;
			count -= n;

			/* Yield control to other fibers. */
			fiber_yield();
			fiber_testcancel();
		}
	}
	@finally {
		[self stopOutput];
	}
}

- (void) onInput
{
	[self subclassResponsibility: _cmd];
}

- (void) onOutput
{
	[self subclassResponsibility: _cmd];
}

@end

@implementation Service

- (id) init: (struct service_config *)config
{
	return [self init: config :[Connection class]];
}

- (id) init: (struct service_config *)config :(Class)conn
{
	self = [super init];
	if (self) {
		listen_fd = -1;
		conn_class = conn;
		ev_init_timer_handler(&timer_event, self);
		ev_init_input_handler(&accept_event, self);
		memcpy(&service_config, config, sizeof(service_config));
	}
	return self;
}

- (void) bind
{
	/* Bind the server socket and start listening. */
	listen_fd = sock_create_server(&service_config.addr,
				       service_config.listen_backlog);

	/* Register the socket with event loop. */
	ev_io_set(&accept_event, listen_fd, EV_READ);
	ev_io_start(&accept_event);

	/* Notify a derived object on the bind. */
	[self onBind];
}

- (void) start
{
	assert(listen_fd == -1);
	@try {
		[self bind];
	}
	@catch (SocketError *e) {
		/* Failed to bind the socket. */
		if (!service_config.bind_retry || e->error != EADDRINUSE) {
			[e log];
			@throw;
		}

		/* Retry mode, try again after delay. */
		say_warn("port %i is already in use, will "
			 "retry binding after %lf seconds.",
			 ntohs(service_config.addr.sin_port),
			 service_config.bind_delay);
		ev_timer_set(&timer_event,
			     service_config.bind_delay,
			     service_config.bind_delay);
		ev_timer_start(&timer_event);
	}
}

- (void) stop
{
	if (listen_fd == -1) {
		ev_timer_stop(&timer_event);
	} else {
		ev_io_stop(&accept_event);
		close(listen_fd);
		listen_fd = -1;
	}
}

- (void) onTimer
{
	assert(listen_fd == -1);
	@try {
		[self bind];
		ev_timer_stop(&timer_event);
	}
	@catch (SocketError *e) {
		if (e->error != EADDRINUSE) {
			[e log];
			@throw;
		}
	}
}

- (void) onInput
{
	assert(listen_fd >= 0);
	@try {
		int fd = sock_accept_client(listen_fd);
		if (fd >= 0) {
			Connection *c = [conn_class new];
			[c open: self :fd];
			[self onConnect: c];
		}
	}
	@catch (SocketError *e) {
		[e log];
	}
}

- (void) onBind
{
	/* No-op by default, override in a derived class if needed. */
}

- (void) onConnect: (Connection *)conn
{
	(void) conn;
	[self subclassResponsibility: _cmd];
}

- (int) getReadAhead
{
	return service_config.readahead;
}

@end

/* }}} */

/* {{{ Single Worker Service and Connection. **********************/

@implementation SingleWorkerConnection

- (void) start: (single_worker_cb)cb
{
	/* Create the worker fiber. */
	worker = fiber_create("TODO", -1, (void (*)(void *)) cb, self);
	if (worker == NULL) {
		say_error("can't create handler fiber, "
			  "dropping client connection");
		[self close];
		[self free];
		return;
	}

	/* Start the worker fiber. It becomes the conn object owner
	   and will have to close and free it before termination. */
	fiber_call(worker);
}

- (void) onInput
{
	fiber_call(worker);
}

- (void) onOutput
{
	fiber_call(worker);
}

@end

@implementation SingleWorkerService

- (id) init: (struct service_config *)config :(single_worker_cb)cb_
{
	self = [super init: config :[SingleWorkerConnection class]];
	if (self) {
		cb = cb_;
	}
	return self;
}

- (void) onConnect: (SingleWorkerConnection *)conn
{
	[conn start: cb];
}

/* }}} */

@end
