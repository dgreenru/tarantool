#ifndef INCLUDES_TARANTOOL_BOX_PORT_H
#define INCLUDES_TARANTOOL_BOX_PORT_H
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

#include <fiber.h>
#include <palloc.h>
#include <util.h>
#import "object.h"

struct iov_buf;
struct tuple;
struct lua_State;

struct port_vtab
{
	u32* (*add_u32)(void *data);
	void (*dup_u32)(void *data, u32 num);
	void (*add_tuple)(void *data, struct tuple *tuple);
	void (*add_lua_multret)(void *data, struct lua_State *L);
};

struct port
{
	struct port_vtab *vtab;
	void *data;
};

/**
 * A hack to keep tuples alive until vbuf is flushed.
 * Is internal to port_iproto implementation, but is also
 * used in memcached.m bypassing PortIproto.
 */
void tuple_guard(struct iov_buf *wbuf, struct tuple *tuple);

/**
 * Create a port instance.
 */
static inline struct port *
port_create(struct port_vtab *vtab, void *data)
{
	struct port *port = palloc(fiber->gc_pool, sizeof(struct port));
	port->vtab = vtab;
	port->data = data;
	return port;
}

static inline u32*
port_add_u32(struct port *port)
{
	return (port->vtab->add_u32)(port->data);
}

static inline void
port_dup_u32(struct port *port, u32 num)
{
	(port->vtab->dup_u32)(port->data, num);
}

static inline void
port_add_tuple(struct port *port, struct tuple *tuple)
{
	(port->vtab->add_tuple)(port->data, tuple);
}

static inline void
port_add_lua_multret(struct port *port, struct lua_State *L)
{
	(port->vtab->add_lua_multret)(port->data, L);
}


u32*
port_null_add_u32(void *data __attribute__((unused)));

void
port_null_dup_u32(void *data __attribute__((unused)),
		  u32 num __attribute__((unused)));

void
port_null_add_tuple(void *data __attribute__((unused)),
		    struct tuple *tuple __attribute__((unused)));

void
port_null_add_lua_multret(void *data __attribute__((unused)),
			  struct lua_State *L __attribute__((unused)));

extern struct port_vtab port_null_vtab;
extern struct port_vtab port_iproto_vtab;

/** This does not have state currently, thus a single
 * instance is sufficient.
 */
extern struct port port_null;

/** Init the subsystem. */
void port_init();
/** Stop the susbystem. */
void port_free();

#endif /* INCLUDES_TARANTOOL_BOX_PORT_H */
