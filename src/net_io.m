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

#include <stdio.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#define DEFAULT_PEER "unknown"

int net_io_readahead;

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

#define CTAB_DEF_SIZE 1024

static Connection **ctab = NULL;
static int ctab_size = 0;

/**
 * Reserve space for the connection table.
 */
static void
conn_reserve(int size)
{
	ctab = realloc(ctab, size * sizeof(Connection *));
	if (ctab == NULL)
		abort();

	while (ctab_size < size) {
		ctab[ctab_size++] = nil;
	}

	say_info("connection table size: %d", ctab_size);
}

/**
 * Initialize the connection table.
 */
static void
conn_init(void)
{
	int size = sysconf(_SC_OPEN_MAX);
	conn_reserve(size > 0 ? size : CTAB_DEF_SIZE);
}

/**
 * Ensure the connection table size.
 */
static void
conn_ensure_size(int n)
{
	if (n >= ctab_size) {
		int size = ctab_size;
		do {
			size *= 2;
		} while (n >= size);
		conn_reserve(size);
	}
}

@implementation Connection

- (id) init: (int)fd_
{
	assert(fd_ >= 0);
	conn_ensure_size(fd_);

	self = [super init];
	if (self) {
		/* Set socket fd. */
		fd = fd_;

		/* Register the connection. */
		assert(ctab[fd] == nil);
		ctab[fd] = self;
	}
	return self;
}

- (void) initInputHandler: (io_handler) handler
{
	/* Prepare for input events. */
	input.data = self;
	ev_init(&input, handler);
	ev_io_set(&input, fd, EV_READ);
}

- (void) initOutputHandler: (io_handler) handler
{
	/* Prepare for output events. */
	output.data = self;
	ev_init(&output, handler);
	ev_io_set(&output, fd, EV_WRITE);
}

- (void) close
{
	assert(fd >= 0);
	assert(fd < ctab_size);
	assert(ctab[fd] == self);

	/* Unregister the connection. */
	ctab[fd] = nil;

	/* Stop I/O events. */
	conn_stop_input(self);
	conn_stop_output(self);

	/* Close the socket. */
	close(fd);
	fd = -1;
}

- (void) info: (struct tbuf *)buf
{
	tbuf_printf(buf, "    sock: %d, name: %s, peer: %s" CRLF, fd, name, peer);
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

@end

/* }}} */

/* {{{ Co-operative Network Connection. ***************************/

@implementation CoConnection

static void
conn_default_handler(ev_io *watcher, int revents __attribute__((unused)))
{
	CoConnection *conn = (CoConnection *) watcher->data;
	fiber_call(conn->worker);
}

void
conn_attach_worker(CoConnection *conn, struct fiber *worker)
{
	assert(conn->worker == NULL && worker->peer == nil);
	conn->worker = worker;
	conn->worker->peer = conn;
}

void
conn_detach_worker(CoConnection *conn)
{
	assert(conn->worker != NULL && conn->worker->peer == conn);
	conn->worker->peer = nil;
	conn->worker = NULL;
}

+ (CoConnection *) connect: (struct sockaddr_in *)addr
{
	CoConnection *conn = nil;
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

		conn = [CoConnection alloc];
		[conn init: fd];
		[conn initInputHandler: conn_default_handler];
		[conn initOutputHandler: conn_default_handler];
	}
	@catch (id) {
		close(fd);
		@throw;
	}
	return conn;
}

- (void) close
{
	if (worker != NULL) {
		conn_detach_worker(self);
	}
	[super close];
}

- (size_t) coRead: (void *)buf :(size_t)count
{
	conn_start_input(self);
	@try {
		size_t total = 0;
		for (;;) {
			/* Read as much data as possible. */
			size_t n = [self read: buf :count];
			if (n == EOF) {
				if (total == 0) {
					return EOF;
				}
				break;
			}

			total += n;
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

		return total;
	}
	@finally {
		conn_stop_input(self);
	}
}

- (size_t) coRead: (void *)buf :(size_t)min_count :(size_t)max_count
{
	assert(min_count <= max_count);
	conn_start_input(self);
	@try {
		size_t total = 0;
		for (;;) {
			/* Read as much data as possible. */
			size_t n = [self read: buf :max_count];
			if (n == EOF) {
				if (total == 0) {
					return EOF;
				}
				break;
			}

			total += n;
			if (total >= min_count) {
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
		conn_stop_input(self);
	}
}

- (void) coWrite: (void *)buf :(size_t)count
{
	conn_start_output(self);
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
		conn_stop_output(self);
	}
}

- (void) coWriteV: (struct iovec *)iov :(int)iovcnt
{
	conn_start_output(self);
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
		conn_stop_output(self);
	}
}

- (size_t) coReadAhead: (struct tbuf *)buf :(size_t)min_count
{
	return [self coReadAhead: buf :min_count :net_io_readahead];
}

- (size_t) coReadAhead: (struct tbuf *)buf :(size_t)min_count :(size_t)readahead
{
	size_t max_count = MAX(min_count, readahead);
	tbuf_ensure(buf, max_count);
	size_t read = [self coRead: buf->data + buf->size :min_count :max_count];
	if (read != EOF) {
		buf->size += read;
	}
	return read;
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
		return;
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
	[conn initInputHandler: [self getInputHandler]];
	[conn initOutputHandler: [self getOutputHandler]];
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

- (io_handler) getInputHandler
{
	return conn_default_handler;
}

- (io_handler) getOutputHandler
{
	return conn_default_handler;
}

@end

/* }}} */

/* {{{ Generic Service Connection. ********************************/

@implementation ServiceConnection

- (id) init: (Service *)service_ :(int)fd_
{
	assert(fd_ >= 0);

	self = [super init: fd_];
	if (self) {
		service = service_;

		/* Set connection name. */
		snprintf(name, sizeof(name), "%i/handler", [service port]);

		/* Set default peer name. */
		assert(strlen(DEFAULT_PEER) < sizeof(peer));
		strcpy(peer, DEFAULT_PEER);

		/* Set default cookie. */
		cookie = 0;
	}
	return self;
}

- (void) initPeer: (struct sockaddr_in *)addr
{
	sock_address_string(addr, peer, sizeof(peer));
	memcpy(&cookie, &addr, MIN(sizeof(addr), sizeof(cookie)));
}

- (u64) cookie
{
	return cookie;
}

- (void) startWorker: (struct fiber *) worker_
{
	assert(fd >= 0);

	conn_attach_worker(self, worker_);
	fiber_call(worker_);
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

/* {{{ Initialization. ********************************************/

void
net_io_init(int readahead)
{
	net_io_readahead = readahead;
	conn_init();
}

void
net_io_info(struct tbuf *out)
{
	tbuf_printf(out, "open connections:" CRLF);
	for (int i = 0; i < ctab_size; i++) {
		[ctab[i] info: out];
	}
}

/* }}} */
