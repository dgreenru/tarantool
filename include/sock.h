#ifndef TARANTOOL_SOCK_H_INCLUDED
#define TARANTOOL_SOCK_H_INCLUDED
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
#include <stdbool.h>
#include <netinet/in.h>
#include <exception.h>

@interface SocketError: SystemError
@end

@interface SocketEOF: SocketError
@end

int sock_create(void);

void sock_blocking_mode(int fd, bool blocking);
void sock_enable_option(int fd, int level, int option);
void sock_enable_option_nc(int fd, int level, int option);
void sock_reset_linger(int fd);

int sock_connect(int fd, struct sockaddr_in *addr);
int sock_connect_inprogress(int fd);

int sock_bind(int fd, struct sockaddr_in *addr);
int sock_accept(int sockfd, struct sockaddr_in *addr, socklen_t *addrlen);
int sock_listen(int fd, int backlog);

size_t sock_read(int fd, void *buf, size_t count);
size_t sock_write(int fd, void *buf, size_t count);
int sock_writev(int fd, struct iovec *iov, int iovcnt);

int sock_peer_name(int fd, struct sockaddr_in *addr);
int sock_address_string(struct sockaddr_in *addr, char *str, size_t len);

#endif /* TARANTOOL_SOCK_H_INCLUDED */
