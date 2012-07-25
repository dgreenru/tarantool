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
#include "port.h"
#include <pickle.h>
#include <fiber.h>
#include <tarantool_lua.h>
#include "tuple.h"
#include <iov_buf.h>
#include "box_lua.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lj_obj.h"
#include "lj_ctype.h"
#include "lj_cdata.h"
#include "lj_cconv.h"
#include <objc/runtime.h>

/*
  For tuples of size below this threshold, when sending a tuple
  to the client, make a deep copy of the tuple for the duration
  of sending rather than increment a reference counter.
  This is necessary to avoid excessive page splits when taking
  a snapshot: many small tuples can be accessed by clients
  immediately after the snapshot process has forked off,
  thus incrementing tuple ref count, and causing the OS to
  create a copy of the memory page for the forked
  child.
*/
const int BOX_REF_THRESHOLD = 8196;

static void
tuple_unref(void *tuple)
{
	tuple_ref((struct tuple *) tuple, -1);
}

void
tuple_guard(struct iov_buf *wbuf, struct tuple *tuple)
{
	tuple_ref(tuple, 1);
	iov_register_cleanup(wbuf, tuple_unref, tuple);
}

u32*
port_null_add_u32(void *data __attribute__((unused)))
{
	static u32 dummy;
	return &dummy;
}

void
port_null_dup_u32(void *data __attribute__((unused)),
		  u32 num __attribute__((unused)))
{
}

void
port_null_add_tuple(void *data __attribute__((unused)),
		    struct tuple *tuple __attribute__((unused)))
{
}

void
port_null_add_lua_multret(void *data __attribute__((unused)),
			  struct lua_State *L __attribute__((unused)))
{
}

static u32*
port_iproto_add_u32(void *data)
{
	struct iov_buf *vbuf = data;
	u32 *p_u32 = palloc(vbuf->pool, sizeof(u32));
	iov_add(vbuf, p_u32, sizeof(u32));
	return p_u32;
}

static void
port_iproto_dup_u32(void *data, u32 num)
{
	struct iov_buf *vbuf = data;
	iov_dup(vbuf, &num, sizeof(u32));
}

static void
port_iproto_add_tuple(void *data, struct tuple *tuple)
{
	struct iov_buf *vbuf = data;
	size_t len = tuple_len(tuple);
	if (len > BOX_REF_THRESHOLD) {
		tuple_guard(vbuf, tuple);
		iov_add(vbuf, &tuple->bsize, len);
	} else {
		iov_dup(vbuf, &tuple->bsize, len);
	}
}

/* Add a Lua table to iov as if it was a tuple, with as little
 * overhead as possible. */

static void
add_lua_table(struct iov_buf *wbuf, struct lua_State *L, int index)
{
	u32 *field_count = palloc(wbuf->pool, sizeof(u32));
	u32 *tuple_len = palloc(wbuf->pool, sizeof(u32));

	*field_count = 0;
	*tuple_len = 0;

	iov_add(wbuf, tuple_len, sizeof(u32));
	iov_add(wbuf, field_count, sizeof(u32));

	u8 field_len_buf[5];
	size_t field_len, field_len_len;
	const char *field;

	lua_pushnil(L);  /* first key */
	while (lua_next(L, index) != 0) {
		++*field_count;

		switch (lua_type(L, -1)) {
		case LUA_TNUMBER:
		{
			u32 field_num = lua_tonumber(L, -1);
			field_len = sizeof(u32);
			field_len_len =
				save_varint32(field_len_buf,
					      field_len) - field_len_buf;
			iov_dup(wbuf, field_len_buf, field_len_len);
			iov_dup(wbuf, &field_num, field_len);
			*tuple_len += field_len_len + field_len;
			break;
		}
		case LUA_TCDATA:
		{
			u64 field_num = tarantool_lua_tointeger64(L, -1);
			field_len = sizeof(u64);
			field_len_len =
				save_varint32(field_len_buf,
					      field_len) - field_len_buf;
			iov_dup(wbuf, field_len_buf, field_len_len);
			iov_dup(wbuf, &field_num, field_len);
			*tuple_len += field_len_len + field_len;
			break;
		}
		case LUA_TSTRING:
		{
			field = lua_tolstring(L, -1, &field_len);
			field_len_len =
				save_varint32(field_len_buf,
					      field_len) - field_len_buf;
			iov_dup(wbuf, field_len_buf, field_len_len);
			iov_dup(wbuf, field, field_len);
			*tuple_len += field_len_len + field_len;
			break;
		}
		default:
			tnt_raise(ClientError, :ER_PROC_RET,
				  lua_typename(L, lua_type(L, -1)));
			break;
		}
		lua_pop(L, 1);
	}
}

static void
add_ret(struct iov_buf *wbuf, struct lua_State *L, int index)
{
	int type = lua_type(L, index);
	struct tuple *tuple;
	switch (type) {
	case LUA_TTABLE:
	{
		add_lua_table(wbuf, L, index);
		return;
	}
	case LUA_TNUMBER:
	{
		size_t len = sizeof(u32);
		u32 num = lua_tointeger(L, index);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), &num, len);
		break;
	}
	case LUA_TCDATA:
	{
		u64 num = tarantool_lua_tointeger64(L, index);
		size_t len = sizeof(u64);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), &num, len);
		break;
	}
	case LUA_TSTRING:
	{
		size_t len;
		const char *str = lua_tolstring(L, index, &len);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), str, len);
		break;
	}
	case LUA_TNIL:
	case LUA_TBOOLEAN:
	{
		const char *str = tarantool_lua_tostring(L, index);
		size_t len = strlen(str);
		tuple = tuple_alloc(len + varint32_sizeof(len));
		tuple->field_count = 1;
		memcpy(save_varint32(tuple->data, len), str, len);
		break;
	}
	case LUA_TUSERDATA:
	{
		tuple = lua_istuple(L, index);
		if (tuple)
			break;
	}
	default:
		/*
		 * LUA_TNONE, LUA_TTABLE, LUA_THREAD, LUA_TFUNCTION
		 */
		tnt_raise(ClientError, :ER_PROC_RET, lua_typename(L, type));
		break;
	}
	tuple_guard(wbuf, tuple);
	iov_add(wbuf, &tuple->bsize, tuple_len(tuple));
}

/**
 * Add all elements from Lua stack to fiber iov.
 *
 * To allow clients to understand a complex return from
 * a procedure, we are compatible with SELECT protocol,
 * and return the number of return values first, and
 * then each return value as a tuple.
 */
static void
port_iproto_add_lua_multret(void *data, struct lua_State *L)
{
	struct iov_buf *vbuf = data;
	int nargs = lua_gettop(L);
	iov_dup(vbuf, &nargs, sizeof(u32));
	for (int i = 1; i <= nargs; ++i)
		add_ret(vbuf, L, i);
}

struct port_vtab port_null_vtab = {
	port_null_add_u32,
	port_null_dup_u32,
	port_null_add_tuple,
	port_null_add_lua_multret,
};

struct port_vtab port_iproto_vtab = {
	port_iproto_add_u32,
	port_iproto_dup_u32,
	port_iproto_add_tuple,
	port_iproto_add_lua_multret,
};

struct port port_null = {
	.vtab = &port_null_vtab,
	.data = NULL,
};

void
port_init()
{
}

void
port_free()
{
}
