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

/**
 * Set non-blocking mode for a socket.
 */
int
sock_nonblocking(int fd)
{
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0) {
		say_syserror("fcntl");
		return -1;
	}
	if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
		say_syserror("fcntl");
		return -1;
	}
	return 0;
}

/**
 * Set an option for a socket.
 */
static inline int
sock_enable_option(int fd, int level, int option)
{
	int on = 1;
	if (setsockopt(fd, level, option, &on, sizeof(on)) < 0) {
		say_syserror("setsockopt");
		return -1;
	}
	return 0;
}

/**
 * Reset linger option for a socket.
 */
static inline int
sock_reset_linger(int fd)
{
	struct linger ling = { 0, 0 };
	if (setsockopt(fd, SOL_SOCKET, SO_LINGER, &ling, sizeof(ling)) != 0) {
		say_syserror("setsockopt");
		return -1;
	}
	return 0;
}

/**
 * Set options appropriate for a client socket.
 */
static int
sock_set_client_options(int fd)
{
	if (sock_nonblocking(fd) < 0) {
		return -1;
	}
	/* These options are not critical, ignore the results. */
	(void) sock_enable_option(fd, SOL_SOCKET, SO_KEEPALIVE);
	(void) sock_enable_option(fd, IPPROTO_TCP, TCP_NODELAY);
	return 0;
}

/**
 * Set options appropriate for a server socket.
 */
static int
sock_set_server_options(int fd)
{
	if (sock_nonblocking(fd) < 0 ||
	    sock_enable_option(fd, SOL_SOCKET, SO_REUSEADDR) < 0 ||
	    sock_enable_option(fd, SOL_SOCKET, SO_KEEPALIVE) < 0 ||
	    sock_reset_linger(fd) < 0) {
		return -1;
	}
	return 0;
}

/**
 * Set options appropriate for an accepted server socket.
 */
static int
sock_set_server_accepted_options(int fd)
{
	if (sock_nonblocking(fd) < 0) {
		return -1;
	}
	/* This option is not critical, ignore the result. */
	(void) sock_enable_option(fd, IPPROTO_TCP, TCP_NODELAY);
	return 0;
}

static int
sock_connect_inprogress(int fd)
{
	/* Wait for the delayed connect() call result. */
	@try {
		// TODO: fd poll
		fiber_yield();
	}
	@catch (id e)	{
		close(fd);
		@throw;
	}

	/* Get the connect() call result. */
	int error = 0;
	socklen_t error_size = sizeof(error);
	if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &error_size) < 0) {
		error = errno;
		say_syserror("getsockopt");
	} else if (error_size != sizeof(error)) {
		error = errno = EINVAL;
		say_syserror("getsockopt");
	} else if (error != 0) {
		errno = error;
		say_syserror("connect");
	}
	return error;
}

/**
 * Create a client socket and connect to a server.
 */
int
sock_connect(struct sockaddr_in *addr)
{
	/* Create a socket. */
	int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) {
		say_syserror("socket");
		return -1;
	}

	/* Set appropriate options. */
	if (sock_set_client_options(fd) < 0) {
		close(fd);
		return -1;
	}

	/* Establish the connection. */
	if (connect(fd, (struct sockaddr *) addr, sizeof(*addr)) < 0) {
		/* Something went wrong... */
		if (errno != EINPROGRESS) {
			/* Connection has failed. */
			say_syserror("connect");
		} else {
			/* Connection has not concluded yet. */
			if (sock_connect_inprogress(fd) == 0)
				return fd;
		}
		close(fd);
		return -1;
	}
	return fd;
}

/**
 * Create a server socket.
 */
int
sock_create(struct sockaddr_in *addr, in_port_t port, int backlog, bool retry, ev_tstamp delay)
{
	/* Minimal delay is 1 msec. */
	static const ev_tstamp min_delay = 0.001;
	if (delay < min_delay) {
		delay = min_delay;
	}

	/* Create a socket. */
	int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) {
		say_syserror("socket");
		return -1;
	}

	/* Set appropriate options. */
	if (sock_set_server_options(fd) < 0) {
		close(fd);
		return -1;
	}

	int bind_count = 0;
bind_retry:
	if (bind(fd, (struct sockaddr *) addr, sizeof(*addr)) < 0) {
		if (retry && errno == EADDRINUSE) {
			/* retry mode, try again after delay */
			if (0 == bind_count++) {
				say_warn("port %i is already in use, will "
					 "retry binding after %lf seconds.",
					 port, delay);
			}
			fiber_sleep(delay);
			goto bind_retry;
		}
		say_syserror("bind");
		close(fd);
		return -1;
	}

	if (listen(fd, backlog) != 0) {
		say_syserror("listen");
		close(fd);
		return -1;
	}

	return fd;
}

/**
 * Accept a connection on a server socket.
 */
int
sock_accept(int sockfd)
{
	int fd = accept(sockfd, NULL, NULL);
	if (fd < 0) {
		if (errno != EAGAIN && errno != EWOULDBLOCK) {
			say_syserror("accept");
		}
		return -1;
	}

	/* Set appropriate options. */
	if (sock_set_server_accepted_options(fd) < 0) {
		close(fd);
		return -1;
	}

	return fd;
}
