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

#include <sock.h>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>

#include <say.h>
#include <fiber.h>

@implementation SocketError
@end

@implementation SocketEOF
@end

/**
 * Get socket option name.
 */
static const char *
sock_get_option_name(int option)
{
#define CASE_OPTION(opt) case opt: return #opt
	switch (option) {
	CASE_OPTION(SO_KEEPALIVE);
	CASE_OPTION(SO_REUSEADDR);
	CASE_OPTION(TCP_NODELAY);
	default:
		return "undefined";
	}
#undef CASE_OPTION
}

/**
 * Create a socket.
 */
static inline int
sock_create(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) {
		tnt_raise(SocketError, :"socket");
	}
	return fd;
}

/**
 * Accept a socket connection.
 */
static inline int
sock_accept(int sockfd)
{
	int fd = accept(sockfd, NULL, NULL);
	if (fd < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			return -1;
		}
		tnt_raise(SocketError, :"accept");
	}
	return fd;
}

/**
 * Set non-blocking mode for a socket.
 */
void
sock_nonblocking(int fd)
{
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0) {
		tnt_raise(SocketError, :"fcntl(..., F_GETFL, ...)");
	}
	flags |= O_NONBLOCK;
	if (fcntl(fd, F_SETFL, flags) < 0) {
		tnt_raise(SocketError, :"fcntl(..., F_SETFL, ...)");
	}
}

/**
 * Set an option for a socket.
 */
static inline void
sock_enable_option(int fd, int level, int option)
{
	int on = 1;
	if (setsockopt(fd, level, option, &on, sizeof(on)) < 0) {
		tnt_raise(SocketError, :"setsockopt(..., %s, ...)",
			  sock_get_option_name(option));
	}
}

/**
 * Reset linger option for a socket.
 */
static inline void
sock_reset_linger(int fd)
{
	struct linger ling = { 0, 0 };
	if (setsockopt(fd, SOL_SOCKET, SO_LINGER, &ling, sizeof(ling)) != 0) {
		tnt_raise(SocketError, :"setsockopt(..., SO_LINGER, ...)");
	}
}

/**
 * Set options appropriate for a client socket.
 */
static void
sock_set_client_options(int fd)
{
	sock_nonblocking(fd);
	/* These options are not critical, ignore the results. */
	@try {
		(void) sock_enable_option(fd, SOL_SOCKET, SO_KEEPALIVE);
		(void) sock_enable_option(fd, IPPROTO_TCP, TCP_NODELAY);
	}
	@catch (SocketError *e) {
		[e log];
	}
}

/**
 * Set options appropriate for a server socket.
 */
static void
sock_set_server_options(int fd)
{
	sock_nonblocking(fd);
	sock_enable_option(fd, SOL_SOCKET, SO_REUSEADDR);
	sock_enable_option(fd, SOL_SOCKET, SO_KEEPALIVE);
	sock_reset_linger(fd);
}

/**
 * Set options appropriate for an accepted server socket.
 */
static void
sock_set_server_accepted_options(int fd)
{
	sock_nonblocking(fd);
	/* This option is not critical, ignore the result. */
	@try {
		(void) sock_enable_option(fd, IPPROTO_TCP, TCP_NODELAY);
	}
	@catch (SocketError *e) {
		[e log];
	}
}

static void
sock_connect_inprogress(int fd)
{
	/* Wait for the delayed connect() call result. */

	// TODO: fd poll

	fiber_yield();

	/* Get the connect() call result. */
	int error = 0;
	socklen_t error_size = sizeof(error);
	if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_size) < 0) {
		tnt_raise(SocketError, :"getsockopt(..., SO_ERROR, ...)");
	} else if (error_size != sizeof(error)) {
		tnt_raise(SocketError, :EINVAL :"getsockopt(..., SO_ERROR, ...)");
	} else if (error != 0) {
		tnt_raise(SocketError, :error :"connect");
	}
}

/**
 * Create a client socket and connect to a server.
 */
int
sock_connect(struct sockaddr_in *addr)
{
	/* Create a socket. */
	int fd = sock_create();
	@try {
		/* Set appropriate options. */
		sock_set_client_options(fd);

		/* Establish the connection. */
		if (connect(fd, (struct sockaddr *) addr, sizeof(*addr)) < 0) {
			/* Something went wrong... */
			if (errno == EINPROGRESS) {
				/* Connection has not concluded yet. */
				sock_connect_inprogress(fd);
			} else {
				/* Connection has failed. */
				tnt_raise(SocketError, :"connect");
			}
		}

		return fd;
	}
	@catch (id e) {
		close(fd);
		@throw;
	}
}

/**
 * Create a server socket.
 */
int
sock_create_server(struct sockaddr_in *addr, int backlog)
{
	/* Create a socket. */
	int fd = sock_create();
	@try {
		/* Set appropriate options. */
		sock_set_server_options(fd);

		/* Go listening on the given address */
		if (bind(fd, (struct sockaddr *) addr, sizeof(*addr)) < 0) {
			tnt_raise(SocketError, :"bind");
		}
		if (listen(fd, backlog) < 0) {
			tnt_raise(SocketError, :"listen");
		}

		return fd;
	}
	@catch (id e) {
		close(fd);
		@throw;
	}
}

/**
 * Accept a client connection on a server socket.
 */
int
sock_accept_client(int sockfd)
{
	/* Accept a connection. */
	int fd = sock_accept(sockfd);
	if (fd < 0) {
		return fd;
	}

	@try {
		/* Set appropriate options. */
		sock_set_server_accepted_options(fd);
		return fd;
	}
	@catch (id e) {
		close(fd);
		@throw;
	}
}

/**
 * Read from a socket.
 */
size_t
sock_read(int fd, void *buf, size_t count)
{
	size_t total = 0;
	while (count > 0) {
		ssize_t n = read(fd, buf, count);
		if (n == 0) {
			if (count) {
				@throw [SocketEOF new];
			}
			break;
		} else if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				break;
			} else if (errno == EINTR) {
				continue;
			}
			tnt_raise(SocketError, :"read");
		}

		buf += n;
		count -= n;
		total += n;
	}
	return total;
}

/**
 * Write to a socket.
 */
size_t
sock_write(int fd, void *buf, size_t count)
{
	size_t total = 0;
	while (count > 0) {
		ssize_t n = write(fd, buf, count);
		if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				break;
			} else if (errno == EINTR) {
				continue;
			}
			tnt_raise(SocketError, :"write");
		}

		buf += n;
		count -= n;
		total += n;
	}
	return total;
}
