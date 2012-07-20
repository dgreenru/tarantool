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
#include "request.h"
#include "txn.h"
#include "tuple.h"
#include "index.h"
#include "space.h"
#include "port.h"
#include "box_lua.h"

#include <errinj.h>
#include <tbuf.h>
#include <pickle.h>
#include <fiber.h>
#include <crope.h>

STRS(requests, REQUESTS);
STRS(update_op_codes, UPDATE_OP_CODES);

static void
read_key(struct tbuf *data, void **key_ptr, u32 *key_part_count_ptr)
{
	void *key = NULL;
	u32 key_part_count = read_u32(data);
	if (key_part_count) {
		key = read_field(data);
		/* advance remaining fields of a key */
		for (int i = 1; i < key_part_count; i++)
			read_field(data);
	}

	*key_ptr = key;
	*key_part_count_ptr = key_part_count;
}

static struct space *
read_space(struct tbuf *data)
{
	u32 space_no = read_u32(data);
	return space_find(space_no);
}

static void
port_send_tuple(u32 flags, Port *port, struct tuple *tuple)
{
	if (tuple) {
		[port dupU32: 1]; /* affected tuples */
		if (flags & BOX_RETURN_TUPLE)
			[port addTuple: tuple];
	} else {
		[port dupU32: 0]; /* affected tuples. */
	}
}

@interface Replace: Request
- (void) execute: (struct txn *) txn :(Port *) port;
@end

@implementation Replace
- (void) execute: (struct txn *) txn :(Port *) port
{
	txn_add_redo(txn, type, data);
	struct space *sp = read_space(data);
	u32 flags = read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS;
	size_t field_count = read_u32(data);

	if (field_count == 0)
		tnt_raise(IllegalParams, :"tuple field count is 0");

	if (data->size == 0 || data->size != valid_tuple(data, field_count))
		tnt_raise(IllegalParams, :"incorrect tuple length");

	txn->new_tuple = tuple_alloc(data->size);
	txn->new_tuple->field_count = field_count;
	memcpy(txn->new_tuple->data, data->data, data->size);

	struct tuple *old_tuple = [sp->index[0] findByTuple: txn->new_tuple];

	if (flags & BOX_ADD && old_tuple != NULL)
		tnt_raise(ClientError, :ER_TUPLE_FOUND);

	if (flags & BOX_REPLACE && old_tuple == NULL)
		tnt_raise(ClientError, :ER_TUPLE_NOT_FOUND);

	space_validate(sp, old_tuple, txn->new_tuple);

	txn_add_undo(txn, sp, old_tuple, txn->new_tuple);

	[port dupU32: 1]; /* Affected tuples */

	if (flags & BOX_RETURN_TUPLE)
		[port addTuple: txn->new_tuple];
}
@end

/** {{{ UPDATE request implementation.
 * UPDATE request is represented by a sequence of operations,
 * each working with a single field. However, there
 * can be more than one operation on the same field.
 * Supported operations are: SET, ADD, bitwise AND, XOR and OR,
 * SPLICE and DELETE.
 *
 * The typical case is when the operation count is much less
 * than field count in a tuple.
 *
 * To ensure minimal use of intermediate memory, UPDATE is
 * performed in a streaming fashion: all operations in the request
 * are sorted by field number. The resulting tuple length is
 * calculated. A new tuple is allocated. Operation are applied
 * sequentially, each copying data from the old tuple to the new
 * data.
 * With this approach we have in most cases linear (tuple length)
 * UPDATE complexity and copy data from the old tuple to the new
 * one only once.
 *
 * There are complications in this scheme caused by multiple
 * operations on the same field: for example, we may have
 * SET(4, "aaaaaa"), SPLICE(4, 0, 5, 0, ""), resulting in
 * zero increase of total tuple length, but requiring an
 * intermediate buffer to store SET results. Please
 * read the source of do_update_ops() to see how these
 * complications  are worked around.
 */


/* ========================================================================= *
 * UPDATE command declaration
 * ========================================================================= */

@interface Update: Request
- (void) execute: (struct txn *) txn :(Port *) port;
@end


/* ========================================================================= *
 * UPDATE command support structures
 * ========================================================================= */

/** Argument of ADD, AND, XOR, OR operations. */
struct op_arith_arg {
	/** Size of argument. */
	u32 size;
	union {
		/** Double word argument. */
		i32 i32_val;
		/** Quad word argument. */
		i64 i64_val;
	};
};

/** Argument of SPLICE. */
struct op_splice_arg {
	/** Cut position. */
	i32 offset;
	/** Cut length. */
	i32 cut;
	/** Paste string. */
	void *paste;
	/** Paste string length. */
	i32 paste_length;
};

/** UPDATE operation context. */
struct update_op {
	/** Operations list. */
	STAILQ_ENTRY(update_op) op_list_entry;
	/** Field number which operation is applied. */
	u32 field_no;
	/** Operation code. */
	u8 opcode;
	/** Operation arguments. */
	union {
		/** Raw operation argument. */
		void *raw;
		/** Arithmetic operation argument. */
		struct op_arith_arg arith;
		/** Splice operation argument. */
		struct op_splice_arg splice;
	} arg;
};

/* List of the update commands. */
STAILQ_HEAD(op_list, update_op);

/** UPDATE command rope entry. */
struct rope_fields {
	/** Fields data. */
	void *data;
	/** Full fields size (w/ field length prefixes). */
	size_t size;
	/** Estimated size of fields after updates (w/o field length prefix). */
	size_t estimated_size;
	/**
	 * Maximal estimated size of fields after updates (w/o field length
	 * prefix).
	 */
	size_t max_estimated_size;
	/** List of UPDATE operations applied to the field. */
	struct op_list op_list;
};

/** A tuple presentation as rope */
crope_decl_struct(tuple, struct rope_fields, struct palloc_pool)

/** UPDATE command context. */
struct update_cmd {
	/** Space. */
	struct space *sp;
	/** Command flags. */
	u32 flags;
	/** Search key. */
	void *key;
	/** Search key part count. */
	u32 key_part_count;
	/** Number of operations */
	size_t op_cnt;
	/** Array of operations. */
	struct update_op *op_buf;
	/** Updated tuple. */
	struct tuple *old_tuple;
};


/* ========================================================================= *
 * UPDATE command support function declaration
 * ========================================================================= */


/* ------------------------------------------------------------------------- *
 * UPDATE command functions declaration
 * ------------------------------------------------------------------------- */

/**
 * Initial read of update command. Unpack and record update operations. Do not
 * do too much, since the subject tuple may not exist.
 * @param data is a raw UPDATE command data.
 * @return read update command, which has an update key and list of operations.
 */
static struct update_cmd *
read_update_cmd(struct tbuf *data);

/**
 * Evaluate an update command.
 * @param cmd is a UPDATE command context.
 * @return a tuple which present as rope.
 */
static struct rope_tuple *
eval_update_ops(struct update_cmd *cmd);

/**
 * Apply an update command.
 * @param tuple is a tuple as a rope.
 * @return an updated tuple.
 */
static struct tuple *
apply_update_ops(struct rope_tuple *tuple);


/* ------------------------------------------------------------------------- *
 * UPDATE tuple evaluate functions declaration
 * ------------------------------------------------------------------------- */

/**
 * Evaluate an UPDATE assign operation.
 * @param tuple is a tuple as a rope.
 * @param op is evaluating operation.
 */
static inline void
eval_update_op_assign(struct rope_tuple *tuple, struct update_op *op);

/**
 * Evaluate an UPDATE arithmetic operation.
 * @param tuple is a tuple as a rope.
 * @param op is an evaluating operation.
 */
static void
eval_update_op_arith(struct rope_tuple *tuple, struct update_op *op);

/**
 * Evaluate an UPDATE splice operation.
 * @param tuple is a tuple as a rope.
 * @param op is an evaluating operation.
 */
static void
eval_update_op_splice(struct rope_tuple *tuple, struct update_op *op);

/**
 * Evaluate an UPDATE insert operation.
 * @param tuple is a tuple as a rope.
 * @param op is an evaluating operation.
 */
static void
eval_update_op_insert(struct rope_tuple *tuple, struct update_op *op);

/**
 * Evaluate an UPDATE delete operation.
 * @param tuple is a tuple as a rope.
 * @param op is an evaluating operation.
 */
static void
eval_update_op_delete(struct rope_tuple *tuple, struct update_op *op);

/**
 * Evaluate a field number for an operation.
 * @param tuple is a tuple as a rope.
 * @param op is an evaluating operation.
 * @return field number.
 */
static inline size_t
eval_update_op_field_no(struct rope_tuple *tuple, struct update_op *op);

/**
 * Evaluate a field number for an insert operation.
 * @param tuple is a tuple as a rope.
 * @param op is an evaluating operation.
 * @return field number.
 */
static inline size_t
eval_update_op_field_no_ins(struct rope_tuple *tuple, struct update_op *op);


/* ------------------------------------------------------------------------- *
 * UPDATE tuple apply functions declaration
 * ------------------------------------------------------------------------- */

/**
 * Apply an UPDATE arithmetic operation.
 * @param field is a field of a tuple.
 */
static void
apply_update_op_list(struct rope_fields *field);

/**
 * Apply an UPDATE arithmetic operation.
 * @param field is a field of a tuple.
 * @param op is an evaluating operation.
 */
static void
apply_update_op_arith(struct rope_fields *field, struct update_op *op);

/**
 * Evaluate an UPDATE splice operation.
 * @param field is a field of a tuple.
 * @param op is an evaluating operation.
 */
static void
apply_update_op_splice(struct rope_fields *field, struct update_op *op);


/* ------------------------------------------------------------------------- *
 * UPDATE tuple rope functions declaration
 * ------------------------------------------------------------------------- */

/**
 * Create a new rope_tuple entry from raw buffer.
 * @param data is fields data.
 * @param size is fields data size.
 * @return an entry which has a tuple.
 */
static inline struct rope_fields *
rope_fields_new(void *data, size_t size);

/**
 * Create a new rope_tuple entry from a tuple.
 * @param tuple is a tuple.
 * @return an entry which has a tuple.
 */
static inline struct rope_fields *
rope_fields_new_tuple(struct tuple *tuple);

/**
 * Split a rope entry on two parts. Head has elements from 0 to pos and tail
 * has elements from pos + 1 to n, where n is number elements in the rope
 * entry.
 * @param entry is a rope entry.
 * @param pos is a split position.
 * @return tail rope entry.
 */
static inline struct rope_fields *
rope_fields_split(struct rope_fields *entry, size_t pos);

/**
 * Print a rope entry (stub function).
 */
static inline void
rope_fields_print(struct rope_fields *entry, size_t size);

/**
 * Free a rope entry (stub function).
 */
static inline void
rope_fields_free(struct palloc_pool *pool, void *ptr);

/* A tuple presentation as rope */
crope_decl_fun(tuple, struct rope_fields, struct palloc_pool)


/* ------------------------------------------------------------------------- *
 * UPDATE command functions definition
 * ------------------------------------------------------------------------- */

static struct update_cmd *
read_update_cmd(struct tbuf *data)
{
	struct update_cmd *cmd = palloc(fiber->gc_pool,
					sizeof(struct update_cmd));
	cmd->sp = read_space(data);
	cmd->flags = read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS;

	read_key(data, &cmd->key, &cmd->key_part_count);

	/* Read number of operations. */
	cmd->op_cnt = read_u32(data);
	if (cmd->op_cnt > BOX_UPDATE_OP_CNT_MAX)
		tnt_raise(ClientError, :ER_UPDATE_TOO_MANY_OPS, cmd->op_cnt);
	if (cmd->op_cnt == 0)
		tnt_raise(ClientError, :ER_UPDATE_NO_OPS);

	/* Read operations. */
	cmd->op_buf = palloc(fiber->gc_pool, (cmd->op_cnt + 1) *
			     sizeof(struct update_op));
	const struct update_op *op_end = cmd->op_buf + cmd->op_cnt;
	for (struct update_op *op = cmd->op_buf; op < op_end; ++op) {
		op->field_no = read_u32(data);
		op->opcode = read_u8(data);
		op->arg.raw = read_field(data);
	}

	/* Try to find a tuple which satisfy the key. */
	cmd->old_tuple = [cmd->sp->index[0] findByKey :cmd->key
						      :cmd->key_part_count];
	return cmd;
}

static struct rope_tuple *
eval_update_ops(struct update_cmd *cmd)
{
	/* Wrap tuple to rope. */
	struct rope_fields *fields = rope_fields_new_tuple(cmd->old_tuple);
	struct rope_tuple *tuple = rope_tuple_new(fields,
						  cmd->old_tuple->field_count,
						  fiber->gc_pool);

	/* Evaluate operation. */
	const struct update_op *op_end = cmd->op_buf + cmd->op_cnt;
	for (struct update_op *op = cmd->op_buf; op < op_end; ++op) {
		switch (op->opcode) {
		case UPDATE_OP_SET:
			eval_update_op_assign(tuple, op);
			break;
		case UPDATE_OP_ADD:
		case UPDATE_OP_AND:
		case UPDATE_OP_XOR:
		case UPDATE_OP_OR:
			eval_update_op_arith(tuple, op);
			break;
		case UPDATE_OP_SPLICE:
			eval_update_op_splice(tuple, op);
			break;
		case UPDATE_OP_INSERT:
			eval_update_op_insert(tuple, op);
			break;
		case UPDATE_OP_DELETE:
			eval_update_op_delete(tuple, op);
			break;
		}
	}

	return tuple;
}

static struct tuple *
apply_update_ops(struct rope_tuple *rope)
{
	/* Checking, has the tuple got fields? */
	if (rope->size == 0)
		/* The tuple's got no fields. */
		tnt_raise(ClientError, :ER_UPDATE_TUPLE_IS_EMPTY);

	size_t tuple_size = 0;
	crope_foreach(tuple, rope, iter) {
		struct rope_fields *field = rope_tuple_iter_value(iter)->data;
		if (!STAILQ_EMPTY(&field->op_list)) {
			/*
			 * Mutable field. The field's got mutable operations
			 * which should be applied.
			 */
			apply_update_op_list(field);
			/* Mutable field keeps data w/o field size prefix. */
			tuple_size += varint32_sizeof(field->size) +
				field->size;
		} else {
			/* Immutable fields. Just get fields size as is. */
			tuple_size += field->size;
		}
	}

	/* Write a new tuple. */
	struct tuple *tuple = tuple_alloc(tuple_size);
	void *tuple_data_ptr = tuple->data;
	tuple->field_count = 0;

	crope_foreach(tuple, rope, iter) {
		struct rope_tuple_leaf *leaf = rope_tuple_iter_value(iter);
		/* */
		tuple->field_count += leaf->size;

		struct rope_fields *field = leaf->data;
		if (!STAILQ_EMPTY(&field->op_list)) {
			/* Mutable field. */
			/* Copy field size. */
			tuple_data_ptr = save_varint32(tuple_data_ptr,
						       field->size);
			/* Copy field data. */
			memcpy(tuple_data_ptr, field->data, field->size);
			tuple_data_ptr += field->size;
		} else {
			/* Immutable fields. Just copy fields as is. */
			memcpy(tuple_data_ptr, field->data, field->size);
			tuple_data_ptr += field->size;
		}
	}

	return tuple;
}


/* ------------------------------------------------------------------------- *
 * UPDATE tuple evaluate functions declaration
 * ------------------------------------------------------------------------- */

static void
eval_update_op_assign(struct rope_tuple *tuple, struct update_op *op)
{
	size_t field_no = eval_update_op_field_no(tuple, op);
	struct rope_fields *field = rope_tuple_extract(tuple, field_no);

	field->data = op->arg.raw;
	field->size = field_full_size(op->arg.raw);
	/*
	 * Clean previous operation list, because any operation before assign
	 * is useless.
	 */
	STAILQ_INIT(&field->op_list);
}

static void
eval_update_op_arith(struct rope_tuple *tuple, struct update_op *op)
{
	/* Get field number. */
	size_t field_no = eval_update_op_field_no(tuple, op);
	/* Extract field from the rope. */
	struct rope_fields *field = rope_tuple_extract(tuple, field_no);

	/* Checking, is it the first mutable operation under the field. */
	if (STAILQ_EMPTY(&field->op_list)) {
		/*
		 * We've got on operation under the field, we should, that's
		 * why we should initialize
		 */
		field->estimated_size = field_size(field->data);
		field->max_estimated_size = field->estimated_size;
	}

	/* Insert the operation to the field list. */
	STAILQ_INSERT_TAIL(&field->op_list, op, op_list_entry);

	/*
	 * Parsing the arguments.
	 */

	/* Read arithmetic operand size */
	void *arg = op->arg.raw;
	op->arg.arith.size = load_varint32(&arg);

	switch (field->estimated_size) {
	case sizeof(int32_t):
		/* 32-bit field. */
		switch (op->arg.arith.size) {
		case sizeof(int32_t):
			op->arg.arith.i32_val = *(i32 *) arg;
			break;
		default:
			tnt_raise(ClientError, :ER_ARG_TYPE, "32-bit int");
		}
		break;
	case sizeof(int64_t):
		/* 64-bit field. */
		switch (op->arg.arith.size) {
		case sizeof(int32_t):
			/* cast 32-bit operand to the 64-bit. */
			op->arg.arith.i64_val = *(int32_t *) arg;
			break;
		case sizeof(int64_t):
			op->arg.arith.i64_val = *(int64_t *) arg;
			break;
		default:
			tnt_raise(ClientError, :ER_ARG_TYPE,
				  "32-bit or 64-bit int");
		}
		break;
	default:
		tnt_raise(ClientError, :ER_FIELD_TYPE, "32-bit or 64-bit int");
	}
}

static void
eval_update_op_splice(struct rope_tuple *tuple, struct update_op *op)
{
	/* Get field number. */
	size_t field_no = eval_update_op_field_no(tuple, op);
	/* Extract field from the rope. */
	struct rope_fields *field = rope_tuple_extract(tuple, field_no);

	/* Checking, is it the first mutable operation under the field. */
	if (STAILQ_EMPTY(&field->op_list)) {
		/*
		 * We've got on operation under the field, we should, that's
		 * why we should initialize
		 */
		field->estimated_size = field_size(field->data);
		field->max_estimated_size = field->estimated_size;
	}

	/* Insert the operation to the field list. */
	STAILQ_INSERT_TAIL(&field->op_list, op, op_list_entry);

	/*
	 * Parsing the arguments.
	 */

	/* Wrap the operands tuple to tbuf structure. */
	void *arg = op->arg.raw;
	u32 arg_size = load_varint32(&arg);
	struct tbuf operands = {
		.capacity = arg_size,
		.size = arg_size,
		.data = arg,
		.pool = NULL
	};

	/*
	 * Offset.
	 */

	/* Read the offset. */
	void *offset_field = read_field(&operands);
	arg_size = load_varint32(&offset_field);
	if (arg_size != sizeof(i32))
		tnt_raise(ClientError, :ER_SPLICE, "invalid offset parameter");
	op->arg.splice.offset = *(i32 *) offset_field;

	/* Validate the offset argument. */
	if (op->arg.splice.offset < 0) {
		/*
		 * Negative offset operand. In this case the measured from the
		 * end of the field.
		 */
		if (-op->arg.splice.offset > field->estimated_size)
			/* Negative offset can't be out of bound. */
			tnt_raise(ClientError, :ER_SPLICE,
				  "offset is out of bound");

		op->arg.splice.offset += field->estimated_size;
	} else if (op->arg.splice.offset > field->estimated_size) {
		/*
		 * The positive offset is out of bound. In this case we set
		 * the offset as end of field.
		 */
		op->arg.splice.offset = field->estimated_size;
	}
	assert(op->arg.splice.offset >= 0 &&
	       op->arg.splice.offset <= field->estimated_size);

	/*
	 * Cut length.
	 */

	/* Read the cut length. */
	void *cut_field = read_field(&operands);
	arg_size = load_varint32(&cut_field);
	if (arg_size != sizeof(i32))
		tnt_raise(ClientError, :ER_SPLICE, "invalid length parameter");

	/* Validate the cut length argument. */
	op->arg.splice.cut = *(i32 *) cut_field;
	if (op->arg.splice.cut < 0) {
		/*
		 * Negative cut length operand. In this case we
		 */
		if (-op->arg.splice.cut >
		    (field->estimated_size - op->arg.splice.offset)) {
			op->arg.splice.cut = 0;
		} else {
			op->arg.splice.cut += field->estimated_size
				- op->arg.splice.offset;
		}
	} else if (op->arg.splice.cut >
		   field->estimated_size - op->arg.splice.offset) {
		op->arg.splice.cut = field->estimated_size -
			op->arg.splice.offset;
	}

	/*
	 * Paste string.
	 */

	void *paste_field = read_field(&operands);
	op->arg.splice.paste_length = load_varint32(&paste_field);
	op->arg.splice.paste = paste_field;

	/* set new estimated size (field_size - cut + paste): */
	size_t new_estimated_size = field->estimated_size;
	new_estimated_size -= op->arg.splice.cut;
	new_estimated_size += op->arg.splice.paste_length;

	field->max_estimated_size = MAX(field->max_estimated_size,
					new_estimated_size);
	field->estimated_size = new_estimated_size;
}

static void
eval_update_op_insert(struct rope_tuple *tuple, struct update_op *op)
{
	/* Get field number. */
	size_t field_no = eval_update_op_field_no_ins(tuple, op);
	/* Create a new field */
	struct rope_fields *field = rope_fields_new(
		op->arg.raw, field_full_size(op->arg.raw));
	/* Insert the field to the tuple. */
	rope_tuple_insert(tuple, field_no, field, 1);
}

static void
eval_update_op_delete(struct rope_tuple *tuple, struct update_op *op)
{
	/* Get field number. */
	size_t field_no = eval_update_op_field_no(tuple, op);
	/* Delete the field which has field_no from the tuple. */
	rope_tuple_remove(tuple, field_no, 1);
}

static inline size_t
eval_update_op_field_no(struct rope_tuple *tuple, struct update_op *op)
{
	if (tuple->size == 0)
		/* The tuple doesn't have any fields. */
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD, op->field_no);

	if ((i32) op->field_no == -1)
		/* delete the last field of the tuple */
		return tuple->size - 1;

	if (op->field_no >= tuple->size)
		/* The tuple doesn't have #field_no field. */
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD, op->field_no);

	return op->field_no;
}

static inline size_t
eval_update_op_field_no_ins(struct rope_tuple *tuple, struct update_op *op)
{
	if ((i32) op->field_no == -1)
		/* delete the last field of the tuple */
		return tuple->size;

	if (op->field_no > tuple->size)
		/* The tuple doesn't have #field_no field. */
		tnt_raise(ClientError, :ER_NO_SUCH_FIELD, op->field_no);

	return op->field_no;
}


/* ------------------------------------------------------------------------- *
 * UPDATE tuple apply functions declaration
 * ------------------------------------------------------------------------- */

static void
apply_update_op_list(struct rope_fields *field)
{
	/*
	 * Move the field to the temporary buffer for apply mutable operations.
	 * A mutable filed keeps in the rope field structure w/o field_size
	 / prefix.
	 */
	void *field_data = field->data;
	size_t field_size = load_varint32(&field_data);
	/* Move the field to the mutable buffer. */
	void *field_data_mut = palloc(fiber->gc_pool,
				      field->max_estimated_size);
	memcpy(field_data_mut, field_data, field_size);
	/* Set mutable buffer as field data. */
	field->data = field_data_mut;
	field->size = field_size;

	/* apply all operation for the field. */
	struct update_op *op;
	STAILQ_FOREACH(op, &field->op_list, op_list_entry) {
		switch (op->opcode) {
		case UPDATE_OP_ADD:
		case UPDATE_OP_AND:
		case UPDATE_OP_XOR:
		case UPDATE_OP_OR:
			/* Apply an arithmetic operation. */
			apply_update_op_arith(field, op);
			break;
		case UPDATE_OP_SPLICE:
			/* Apply an splice operation. */
			apply_update_op_splice(field, op);
			break;
		}
	}
}

static void
apply_update_op_arith(struct rope_fields *field, struct update_op *op)
{
	switch (field->size) {
	case sizeof(int32_t): {
		/* 32-bit arithmetic operations. */
		int32_t *field_value = field->data;
		switch (op->opcode) {
		case UPDATE_OP_ADD:
			*field_value += op->arg.arith.i32_val;
			break;
		case UPDATE_OP_AND:
			*field_value &= op->arg.arith.i32_val;
			break;
		case UPDATE_OP_XOR:
			*field_value ^= op->arg.arith.i32_val;
			break;
		case UPDATE_OP_OR:
			*field_value |= op->arg.arith.i32_val;
			break;
		}
		break;
	}
	case sizeof(int64_t): {
		/* 64-bit arithmetic operations. */
		int64_t *field_value = field->data;
		switch (op->opcode) {
		case UPDATE_OP_ADD:
			*field_value += op->arg.arith.i64_val;
			break;
		case UPDATE_OP_AND:
			*field_value &= op->arg.arith.i64_val;
			break;
		case UPDATE_OP_XOR:
			*field_value ^= op->arg.arith.i64_val;
			break;
		case UPDATE_OP_OR:
			*field_value |= op->arg.arith.i64_val;
			break;
		}
		break;
	}
	}
}

static void
apply_update_op_splice(struct rope_fields *field, struct update_op *op)
{
	/*
	 * Splice scheme:
	 *
	 * |<----------------- field->size -------------------->|
	 * |                                                    |
	 * |---- offset ----|<---- cut ---->|<----- tail ------>|
	 * +----------------+---------------+-----+-------------+
	 * |                      field                         |
	 * +----------------+---------------+-----+-------------+
	 *                  |<------ paste ------>|
	 */

	/*
	 * Move the tail of the field.
	 */

	size_t tail_size = field->size - op->arg.splice.offset -
		op->arg.splice.cut;
	if (tail_size != 0) {
		/*
		 * The tail of the field isn't empty. We should move it to the
		 * end of the paste position.
		 */
		void *tail_src = field->data + op->arg.splice.offset +
			op->arg.splice.cut;
		void *tail_dest = field->data + op->arg.splice.offset +
			op->arg.splice.paste_length;
		memmove(tail_dest, tail_src, tail_size);
	}

	/*
	 * Copy the paste string to the field.
	 */

	if (op->arg.splice.paste_length != 0) {
		void *paste_dest = field->data + op->arg.splice.offset;
		memcpy(paste_dest, op->arg.splice.paste,
		       op->arg.splice.paste_length);
	}


	/*
	 * New field size
	 */
	field->size = field->size - op->arg.splice.cut +
		op->arg.splice.paste_length;
}


/* ------------------------------------------------------------------------- *
 * UPDATE tuple rope functions definition
 * ------------------------------------------------------------------------- */

static inline struct rope_fields *
rope_fields_new_tuple(struct tuple *tuple)
{
	struct rope_fields *entry = palloc(fiber->gc_pool,
					  sizeof(struct rope_fields));

	entry->data = tuple->data;
	entry->size = tuple->bsize;
	STAILQ_INIT(&entry->op_list);

	return entry;
}

static inline struct rope_fields *
rope_fields_new(void *data, size_t size)
{
	struct rope_fields *entry = palloc(fiber->gc_pool,
					  sizeof(struct rope_fields));
	entry->data = data;
	entry->size = size;
	STAILQ_INIT(&entry->op_list);

	return entry;
}

static struct rope_fields *
rope_fields_split(struct rope_fields *entry, size_t pos)
{
	struct tbuf fields = {
		.capacity = entry->size,
		.size = entry->size,
		.data = entry->data,
		.pool = NULL
	};

	/* Move field buffer to the pos field. */
	for (int i = 0; i < pos; ++i)
		read_field(&fields);

	struct rope_fields *tail = palloc(fiber->gc_pool,
					  sizeof(struct rope_fields));

	/* Create the new (the tail) entry. */
	tail->data = fields.data;
	tail->size = fields.size;
	STAILQ_INIT(&tail->op_list);

	/* Update the old (the head) entry. */
	entry->size = entry->size - fields.size;

	return tail;
}

static inline void
rope_fields_print(struct rope_fields *entry, size_t size)
{
	(void) entry; (void) size;
}

static inline void
rope_fields_free(struct palloc_pool *pool, void *ptr)
{
	(void) pool; (void) ptr;
}

crope_define_fun(tuple,
		 struct rope_fields,
		 struct palloc_pool,
		 rope_fields_split,
		 rope_fields_print,
		 palloc,
		 rope_fields_free);


/* ========================================================================= *
 * UPDATE command definition
 * ========================================================================= */

@implementation Update
- (void) execute: (struct txn *) txn :(Port *) port
{
	txn_add_redo(txn, type, data);

	/* Parse UPDATE request. */
	struct update_cmd *cmd = read_update_cmd(data);
	if (cmd->old_tuple != NULL) {
		struct rope_tuple *eval_tuple = eval_update_ops(cmd);
		txn->new_tuple = apply_update_ops(eval_tuple);
		space_validate(cmd->sp, cmd->old_tuple, txn->new_tuple);
	}

	txn_add_undo(txn, cmd->sp, cmd->old_tuple, txn->new_tuple);
	port_send_tuple(cmd->flags, port, txn->new_tuple);
}
@end

/** }}} */

@interface Select: Request
- (void) execute: (struct txn *) txn :(Port *) port;
@end

@implementation Select
- (void) execute: (struct txn *) txn :(Port *) port
{
	(void) txn; /* Not used. */
	struct space *sp = read_space(data);
	u32 index_no = read_u32(data);
	Index *index = index_find(sp, index_no);
	u32 offset = read_u32(data);
	u32 limit = read_u32(data);
	u32 count = read_u32(data);
	if (count == 0)
		tnt_raise(IllegalParams, :"tuple count must be positive");

	uint32_t *found = palloc(fiber->gc_pool, sizeof(*found));
	*found = 0;
	[port addU32: found];

	ERROR_INJECT_EXCEPTION(ERRINJ_TESTING);

	for (u32 i = 0; i < count; i++) {

		/* End the loop if reached the limit. */
		if (limit == *found)
			return;

		/* read key */
		u32 key_part_count;
		void *key;
		read_key(data, &key, &key_part_count);

		struct iterator *it = index->position;
		[index initIteratorByKey: it :ITER_FORWARD :key :key_part_count];

		struct tuple *tuple;
		while ((tuple = it->next_equal(it)) != NULL) {
			if (tuple->flags & GHOST)
				continue;

			if (offset > 0) {
				offset--;
				continue;
			}

			[port addTuple: tuple];

			if (limit == ++(*found))
				break;
		}
	}
	if (data->size != 0)
		tnt_raise(IllegalParams, :"can't unpack request");
}
@end

@interface Delete: Request
- (void) execute: (struct txn *) txn :(Port *) port;
@end

@implementation Delete
- (void) execute: (struct txn *) txn :(Port *) port
{
	txn_add_redo(txn, type, data);
	u32 flags = 0;
	struct space *sp = read_space(data);
	if (type == DELETE)
		flags |= read_u32(data) & BOX_ALLOWED_REQUEST_FLAGS;
	/* read key */
	u32 key_part_count;
	void *key;
	read_key(data, &key, &key_part_count);
	/* try to find tuple in primary index */
	struct tuple *old_tuple = [sp->index[0] findByKey :key :key_part_count];

	txn_add_undo(txn, sp, old_tuple, NULL);

	port_send_tuple(flags, port, old_tuple);
}
@end

@implementation Request
+ (Request *) alloc
{
	size_t sz = class_getInstanceSize(self);
	id new = palloca(fiber->gc_pool, sz, sizeof(void *));
	memset(new, 0, sz);
	object_setClass(new, self);
	return new;
}

+ (Request *) build: (u32) type_arg
{
	Request *new = nil;
	switch (type_arg) {
	case REPLACE:
		new = [Replace alloc]; break;
	case SELECT:
		new = [Select alloc]; break;
	case UPDATE:
		new = [Update alloc]; break;
	case DELETE_1_3:
	case DELETE:
		new = [Delete alloc]; break;
	case CALL:
		new = [Call alloc]; break;
	default:
		say_error("Unsupported request = %" PRIi32 "", type_arg);
		tnt_raise(IllegalParams, :"unsupported command code, "
			  "check the error log");
		break;
	}
	new->type = type_arg;
	return new;
}

- (id) init: (struct tbuf *) data_arg
{
	assert(type);
	self = [super init];
	if (self == nil)
		return self;

	data = data_arg;
	return self;
}

- (void) execute: (struct txn *) txn :(Port *) port
{
	(void) txn;
	(void) port;
	[self subclassResponsibility: _cmd];
}
@end

