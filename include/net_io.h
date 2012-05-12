#ifndef TARANTOOL_NET_IO_H_INCLUDED
#define TARANTOOL_NET_IO_H_INCLUDED
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

#include <fiber.h>
#include <iproto.h>
#include <tarantool_ev.h>
#include <third_party/queue.h>
#include <util.h>

#include <stdbool.h>
#include <netinet/in.h>

#import <objc/Object.h>

#define SERVICE_NAME_MAXLEN FIBER_NAME_MAXLEN

STAILQ_HEAD(input_queue, input_buffer);
struct input_buffer
{
	STAILQ_ENTRY(input_buffer) next;
	u32 size;
	u8 data[];
};

STAILQ_HEAD(output_queue, output_buffer);
struct output_buffer
{
	STAILQ_ENTRY(output_buffer) next;
};

STAILQ_HEAD(request_queue, request);
struct request
{
	STAILQ_ENTRY(request) next;
	struct connection *connection;
	struct fiber *worker;
};

@protocol TimerHandler
- (void) onTimer;
@end

@protocol InputHandler
- (void) onInput;
@end

@protocol OutputHandler
- (void) onOutput;
@end

void ev_init_timer_handler(ev_timer *watcher, id<TimerHandler> handler);
void ev_init_input_handler(ev_io *watcher, id<InputHandler> handler);
void ev_init_output_handler(ev_io *watcher, id<OutputHandler> handler);


struct service_config
{
	const char *name;
	struct sockaddr_in addr;
	int listen_backlog;
	bool bind_retry;
	ev_tstamp bind_delay;
	int readahead;
};

/* Forward declarations */
@class Connection;
@class IProtoConnection;
@class SingleWorkerConnection;


/**
 * Generic Network Service.
 */
@interface Service: Object <TimerHandler, InputHandler> {
	int listen_fd;
	struct ev_timer timer_event;
	struct ev_io accept_event;
	struct service_config service_config;
	char service_name[SERVICE_NAME_MAXLEN];
}

/* Entry points. */
- (id) init: (const char *)name :(int)port;
- (id) init: (struct service_config *)config;
- (const char *) name;
- (int) port;
- (int) readahead;
- (void) start;
- (void) stop;

/* Extension points. */
- (void) onBind;
- (Connection *) allocConnection;
- (void) onConnect: (Connection *) conn;

/* Internal methods. */
- (bool) bind;

@end


/**
 * Abstract Network Connection.
 */
@interface Connection: Object <InputHandler, OutputHandler> {
@public
	struct fiber *worker;
@protected
	int fd;
	struct ev_io input;
	struct ev_io output;
	Service *service;
	char name[SERVICE_NAME_MAXLEN];
	char peer[SERVICE_NAME_MAXLEN];
	u64 cookie;
}

- (id) init: (Service *)service_ :(int)fd_;
- (const char *) name;
- (const char *) peer;
- (u64) cookie;
- (void) start: (struct fiber *) worker_;
- (void) close;

/* Event control */
- (void) startInput;
- (void) stopInput;
- (void) startOutput;
- (void) stopOutput;

/* Non-blocking I/O */
- (size_t) read: (void *)buf :(size_t)count;
- (size_t) write: (void *)buf :(size_t)count;

/* Co-operative blocking I/O */
- (void) coRead: (void *)buf :(size_t)count;
- (int) coRead: (void *)buf :(size_t)min_count :(size_t)max_count;
- (void) coReadAhead: (struct tbuf *)buf :(size_t)min_count;
- (void) coWrite: (void *)buf :(size_t)count;

@end


/**
 * IProto Service.
 */
@interface IProtoService: Service {
}

- (void) input: (Connection *) conn;
- (void) output: (Connection *) conn;

/* Extension point. */
- (void) process: (uint32_t) msg_code :(struct tbuf *) request;

@end


/**
 * IProto Connection.
 */
@interface IProtoConnection: Connection {
	//struct request_queue queue;
	//struct input_queue input_queue;
	//struct output_queue output_queue;
}

@end


/** Define the callback for single worker connections. */
typedef void (*single_worker_cb)(SingleWorkerConnection *conn);


/**
 * Service that creates connections with a single dedicated worker fiber.
 */
@interface SingleWorkerService: Service {
	single_worker_cb cb;
}

/** Factory method */
+ (SingleWorkerService *) create: (const char *)name
				:(int)port
				:(single_worker_cb)cb;
- (id) init: (struct service_config *)config :(single_worker_cb)cb;

@end;


/**
 * Connection with a single dedicated worker fiber.
 */
@interface SingleWorkerConnection: Connection

@end

#endif /* TARANTOOL_NET_IO_H_INCLUDED */
