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

#include <sock.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#include <say.h>
#include <fiber.h>

@implementation SocketError
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
int
sock_create(void)
{
	int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
	if (fd < 0) {
		tnt_raise(SocketError, :"socket");
	}
	return fd;
}

/**
 * Set blocking mode for a socket.
 */
void
sock_set_blocking(int fd, bool blocking)
{
	int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0) {
		tnt_raise(SocketError, :"fcntl(..., F_GETFL, ...)");
	}

	if (blocking) {
		flags &= ~O_NONBLOCK;
	} else {
		flags |= O_NONBLOCK;
	}

	if (fcntl(fd, F_SETFL, flags) < 0) {
		tnt_raise(SocketError, :"fcntl(..., F_SETFL, ...)");
	}
}

/**
 * Set an option for a socket.
 */
void
sock_set_option(int fd, int level, int option)
{
	int on = 1;
	if (setsockopt(fd, level, option, &on, sizeof(on)) < 0) {
		tnt_raise(SocketError, :"setsockopt(..., %s, ...)",
			  sock_get_option_name(option));
	}
}

/**
 * Set a non-critical option for a socket.
 */
void
sock_set_option_nc(int fd, int level, int option)
{
	int on = 1;
	if (setsockopt(fd, level, option, &on, sizeof(on)) < 0) {
		say_syserror("setsockopt(..., %s, ...)",
			     sock_get_option_name(option));
	}
}

/**
 * Reset linger option for a socket.
 */
void
sock_reset_linger(int fd)
{
	struct linger ling = { 0, 0 };
	if (setsockopt(fd, SOL_SOCKET, SO_LINGER, &ling, sizeof(ling)) != 0) {
		tnt_raise(SocketError, :"setsockopt(..., SO_LINGER, ...)");
	}
}

/**
 * Connect a client socket to a server.
 */
int
sock_connect(int fd, struct sockaddr_in *addr, socklen_t addrlen)
{
	/* Establish the connection. */
	if (connect(fd, (struct sockaddr *) addr, addrlen) < 0) {
		/* Something went wrong... */
		if (errno == EINPROGRESS) {
			/* Connection has not concluded yet. */
			return -1;
		} else {
			/* Connection has failed. */
			tnt_raise(SocketError, :"connect");
		}
	}
	return 0;
}

/**
 * Complete inprogress connection.
 */
int
sock_connect_inprogress(int fd)
{
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
	return 0;
}

/**
 * Bind a socket to the given address.
 */
int
sock_bind(int fd, struct sockaddr_in *addr, socklen_t addrlen)
{
	if (bind(fd, (struct sockaddr *) addr, addrlen) < 0) {
		if (errno == EADDRINUSE) {
			return -1;
		}
		tnt_raise(SocketError, :"bind");
	}
	return 0;
}

/**
 * Mark a socket as accepting connections.
 */
int
sock_listen(int fd, int backlog)
{
	if (listen(fd, backlog) < 0) {
		if (errno == EADDRINUSE) {
			return -1;
		}
		tnt_raise(SocketError, :"listen");
	}
	return 0;
}

/**
 * Accept a client connection on a server socket.
 */
int
sock_accept(int sockfd, struct sockaddr_in *addr, socklen_t *addrlen)
{
	/* Accept a connection. */
	int fd = accept(sockfd, (struct sockaddr *) addr, addrlen);
	if (fd < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			return -1;
		}
		tnt_raise(SocketError, :"accept");
	}
	return fd;
}

/**
 * Read from a socket.
 */
size_t
sock_read(int fd, void *buf, size_t count)
{
	size_t orig_count = count;
	while (count > 0) {
		ssize_t n = read(fd, buf, count);
		if (n == 0) {
			return EOF;
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
	}
	return (orig_count - count);
}

/**
 * Write to a socket.
 */
size_t
sock_write(int fd, void *buf, size_t count)
{
	size_t orig_count = count;
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
	}
	return (orig_count - count);
}

/**
 * Write to a socket with iovec.
 *
 * NB: Despite similar signature the contract for this function
 * substantially differs from the underlying writev system call.
 * Instead of the number of written bytes it returns the number
 * of iovecs that were completely written. For a partial write
 * the individual iovec following those completely written will
 * have the iov_len and iov_base fields updated to reflect how
 * much data remains to be written. Also for iovecs completely
 * written these fields may be modified too as a side affect of
 * the function going through them. These modifications bear no
 * meaning to the caller.
 */
int
sock_writev(int fd, struct iovec *iov, int iovcnt)
{
	size_t orig_iovcnt = iovcnt;
	while (iovcnt > 0) {
		int cnt = iovcnt < IOV_MAX ? iovcnt : IOV_MAX;
		ssize_t n = writev(fd, iov, cnt);
		if (n < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				break;
			} else if (errno == EINTR) {
				continue;
			}
			tnt_raise(SocketError, :"writev");
		}

		while (n > iov->iov_len) {
			n -= iov->iov_len;
			iov++;
			iovcnt--;
		}
		if (n == iov->iov_len) {
			iov++;
			iovcnt--;
		} else {
			iov->iov_base += n;
			iov->iov_len -= n;
		}
	}
	return (orig_iovcnt - iovcnt);
}

/**
 * Get socket peer name.
 */
int
sock_peer_name(int fd, struct sockaddr_in *addr, socklen_t *addrlen)
{
	if (getpeername(fd, (struct sockaddr *)addr, addrlen) < 0)
		return -1;
	if (addr->sin_addr.s_addr == 0)
		return -1;
	return 0;
}

/**
 * Convert address to a string.
 */
int
sock_address_string(struct sockaddr_in *addr, char *str, size_t len)
{
	return snprintf(str, len, "%s:%d",
			inet_ntoa(addr->sin_addr),
			ntohs(addr->sin_port));
}

