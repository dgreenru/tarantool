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

#include <net_io.h>
#include <sock.h>
#include <tarantool.h>

#include <netinet/in.h>
#include <netinet/tcp.h>

#define DEFAULT_PEER "unknown"

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

static void
preio_cb(ev_watcher *watcher, int revents __attribute__((unused)))
{
	id <PreIOHandler> handler = watcher->data;
	[handler preIO];
}

static void
postio_cb(ev_watcher *watcher, int revents __attribute__((unused)))
{
	id <PostIOHandler> handler = watcher->data;
	[handler postIO];
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

void ev_init_preio_handler(ev_check *watcher, id<PreIOHandler> handler)
{
	watcher->data = handler;
	ev_init(watcher, (void *) preio_cb);
}

void ev_init_postio_handler(ev_prepare *watcher, id<PostIOHandler> handler)
{
	watcher->data = handler;
	ev_init(watcher, (void *) postio_cb);
}

/* }}} */

/* {{{ Generic Network Connection. ********************************/

@implementation Connection

- (id) init: (int)fd_
{
	assert(fd_ >= 0);

	self = [super init];
	if (self) {
		/* Set socket fd. */
		fd = fd_;

		/* Prepare for input events. */
		ev_init_input_handler(&input, self);
		ev_io_set(&input, fd, EV_READ);

		/* Prepare for output events. */
		ev_init_output_handler(&output, self);
		ev_io_set(&output, fd, EV_WRITE);
	}
	return self;
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
	return sock_read(fd, buf, count);
}

- (size_t) write: (void *)buf :(size_t)count
{
	assert(fd >= 0);
	return sock_write(fd, buf, count);
}

- (int) writev: (struct iovec *)iov :(int)iovcnt
{
	assert(fd >= 0);
	return sock_writev(fd, iov, iovcnt);
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

/* }}} */

/* {{{ Co-operative Network Connection. ***************************/

@implementation CoConnection

+ (CoConnection *) connect: (struct sockaddr_in *)addr
{
	int fd = sock_create();
	@try {
		sock_set_blocking(fd, false);
		/* These options are not critical, ignore the results. */
		sock_set_option_nc(fd, SOL_SOCKET, SO_KEEPALIVE);
		sock_set_option_nc(fd, IPPROTO_TCP, TCP_NODELAY);

		if (sock_connect(fd, addr, sizeof(*addr)) < 0) {
			assert(errno == EINPROGRESS);
			fiber_io_wait(fd, EV_WRITE);
			sock_connect_inprogress(fd);
		}

		CoConnection *conn = [CoConnection alloc];
		[conn init: fd];
		return conn;
	}
	@catch (id) {
		close(fd);
		@throw;
	}
}

- (void) close
{
	if (worker != NULL) {
		[self detachWorker];
	}
	[super close];
}

- (void) attachWorker: (struct fiber *)worker_
{
	assert(worker == NULL && worker_->peer == nil);
	worker = worker_;
	worker->peer = self;
}

- (void) detachWorker
{
	assert(worker != NULL && worker->peer == self);
	worker->peer = nil;
	worker = NULL;
}

- (void) coWork
{
	assert(worker != NULL);
	fiber_call(worker);
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

- (void) coWriteV: (struct iovec *)iov :(int)iovcnt
{
	[self startOutput];
	@try {
		for (;;) {
			/* Write as much data as possible. */
			int n = [self writev: iov :iovcnt];
			if (n == iovcnt) {
				break;
			}

			/* Go past the data just written. */
			iov += n;
			iovcnt -= n;

			/* Yield control to other fibers. */
			fiber_yield();
			fiber_testcancel();
		}
	}
	@finally {
		[self stopOutput];
	}
}

- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count
{
	[self coReadAhead: buf :min_count :(16 * 1024)];
}

- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count :(size_t)readahead
{
	size_t max_count = MAX(min_count, readahead);
	tbuf_ensure(buf, max_count);
	buf->size += [self coRead: buf->data + buf->size :min_count :max_count];
}

- (void) onInput
{
	[self coWork];
}

- (void) onOutput
{
	[self coWork];
}

- (const char *) peer
{
	return NULL;
}

- (u64) cookie
{
	return 0;
}

@end

/* }}} */

/* {{{ Connection Acceptor. ***************************************/

/**
 * Bind the server socket and start listening.
 */
static int
bind_and_listen(int listen_fd, struct sockaddr_in *addr, int backlog)
{
	if (sock_bind(listen_fd, addr, sizeof(*addr)) < 0) {
		return -1;
	}
	if (sock_listen(listen_fd, backlog) < 0) {
		return -1;
	}
	return 0;
}

@implementation Acceptor

- (id) init: (struct service_config *)config
{
	self = [super init];
	if (self) {
		listen_fd = -1;
		ev_init_timer_handler(&timer_event, self);
		ev_init_input_handler(&accept_event, self);
		memcpy(&service_config, config, sizeof(service_config));
	}
	return self;
}

- (bool) bind
{
	@try {
		/* Create a socket. */
		listen_fd = sock_create();

		/* Set appropriate options. */
		sock_set_blocking(listen_fd, false);
		sock_set_option(listen_fd, SOL_SOCKET, SO_REUSEADDR);
		sock_set_option(listen_fd, SOL_SOCKET, SO_KEEPALIVE);
		sock_reset_linger(listen_fd);

		/* Try to bind the socket. */
		if (bind_and_listen(listen_fd,
				    &service_config.addr,
				    service_config.listen_backlog) < 0) {
			if (service_config.bind_retry) {
				[self close];
				return false;
			}
			tnt_raise(SocketError, :"bind/listen");
		}
		say_info("bound to port %i", [self port]);
	}
	@catch (SocketError *e) {
		/* Failed to bind the socket. */
		[self close];
		[e log];
		say_error("Failed to init a server socket on port %i", [self port]);
		@throw;
	}

	/* Notify a derived object on the bind event. */
	@try {
		[self onBind];
	}
	@catch (id) {
		[self close];
		@throw;
	}

	/* Register the socket with the event loop. */
	ev_io_set(&accept_event, listen_fd, EV_READ);
	ev_io_start(&accept_event);

	return true;
}

- (void) close
{
	if (listen_fd > 0) {
		close(listen_fd);
		listen_fd = -1;
	}
}

- (void) start
{
	assert(listen_fd == -1);

	if (![self bind]) {
		/* Retry mode, try again after delay. */
		say_warn("port %i is already in use, will "
			 "retry binding after %lf seconds.",
			 [self port], service_config.bind_delay);
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
		[self close];
	}
}

- (int) port
{
	return ntohs(service_config.addr.sin_port);
}

- (void) onTimer
{
	assert(listen_fd == -1);

	if ([self bind]) {
		ev_timer_stop(&timer_event);
	}
}

- (void) onInput
{
	assert(listen_fd >= 0);

	int fd;
	struct sockaddr_in addr;
	socklen_t addrlen = sizeof(addr);
	@try {
		fd = sock_accept(listen_fd, &addr, &addrlen);
		if (fd < 0) {
			return;
		}
	}
	@catch (SocketError *e) {
		[e log];
	}

	/* Notify a derived object on the accept event. */
	@try {
		[self onAccept: fd :&addr];
	}
	@catch (id) {
		close(fd);
	}
}

- (void) onBind
{
	/* No-op by default, override in a derived class if needed. */
}

- (void) onAccept: (int)fd :(struct sockaddr_in *)addr
{
	(void) fd;
	(void) addr;
	[self subclassResponsibility: _cmd];
}

@end

/* {{{ Generic Network Service. ***********************************/

@implementation Service

- (id) init: (const char *)name :(struct service_config *)config
{
	self = [super init: config];
	if (self) {
		snprintf(service_name, sizeof(service_name),
			 "%i/%s", [self port], name);
	}
	return self;
}

- (const char *) name
{
	return service_name;
}

- (int) readahead
{
	return service_config.readahead;
}

- (void) onBind
{
	/* No-op by default, override in a derived class if needed. */
}

- (void) onAccept: (int)fd :(struct sockaddr_in *)addr
{
	/* Set socket options. */
	sock_set_blocking(fd, false);
	sock_set_option_nc(fd, IPPROTO_TCP, TCP_NODELAY);
	/* Create and initialize a connection object. */
	ServiceConnection *conn = [self allocConnection];
	[conn init: self :fd];
	[conn initPeer: addr];
	/* Delegate the use of the connection to a subclass. */
	[self onConnect: conn];
}

- (ServiceConnection *) allocConnection
{
	return [ServiceConnection alloc];
}

- (void) onConnect: (ServiceConnection *)conn
{
	(void) conn;
	[self subclassResponsibility: _cmd];
}

@end

/* }}} */

/* {{{ Abstract Network Connection. *******************************/

@implementation ServiceConnection

- (id) init: (Service *)service_ :(int)fd_
{
	assert(fd_ >= 0);

	self = [super init];
	if (self) {
		service = service_;
		fd = fd_;

		/* Set connection name. */
		snprintf(name, sizeof(name), "%i/handler", [service port]);

		/* Set default peer name. */
		assert(strlen(DEFAULT_PEER) < sizeof(peer));
		strcpy(peer, DEFAULT_PEER);

		/* Set default cookie. */
		cookie = 0;

		/* Prepare for input events. */
		ev_init_input_handler(&input, self);
		ev_io_set(&input, fd, EV_READ);

		/* Prepare for output events. */
		ev_init_output_handler(&output, self);
		ev_io_set(&output, fd, EV_WRITE);
	}
	return self;
}

- (void) initPeer: (struct sockaddr_in *)addr
{
	sock_address_string(addr, peer, sizeof(peer));
	memcpy(&cookie, &addr, MIN(sizeof(addr), sizeof(cookie)));
}

- (const char *) name
{
	return name;
}

- (const char *) peer
{
	return peer;
}

- (u64) cookie
{
	return cookie;
}

- (void) startWorker: (struct fiber *) worker_
{
	assert(fd >= 0);

	[self attachWorker: worker_];
	[self coWork];
}

- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count
{
	[super coReadAhead: buf :min_count :[service readahead]];
}

@end

/* }}} */

/* {{{ Single Worker Service and Connection. **********************/

@implementation SingleWorkerService

+ (SingleWorkerService *) create: (const char *)name
				:(int)port
				:(single_worker_cb)cb
{
	struct service_config config;
	tarantool_config_service(&config, port);
	SingleWorkerService *service = [SingleWorkerService alloc];
	[service init: name :&config :cb];
	return service;
}

- (id) init: (const char *)name
	   :(struct service_config *)config
	   :(single_worker_cb)cb_
{
	self = [super init: name :config];
	if (self) {
		cb = cb_;
	}
	return self;
}

- (void) onConnect: (ServiceConnection *) conn
{
	/* Create the worker fiber. */
	struct fiber *worker = fiber_create([conn name],
					    (void (*)(void *)) cb, conn);
	if (worker == NULL) {
		say_error("can't create handler fiber, "
			  "dropping client connection");
		[conn close];
		[conn free];
		return;
	}

	/* Start the worker fiber. It becomes the conn object owner
	   and will have to close and free it before termination. */
	[conn startWorker: worker];
}

@end

/* }}} */
