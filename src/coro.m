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
#include "coro.h"

#include "config.h"
#include "exception.h"
#include <unistd.h>
#include <string.h>
#include <sys/mman.h>

#include "third_party/valgrind/memcheck.h"

void
tarantool_coro_init(struct tarantool_coro *coro,
		    void (*f) (void *), void *data)
{
	const int page = sysconf(_SC_PAGESIZE);

	memset(coro, 0, sizeof(*coro));

	/* TODO: guard pages */
	coro->stack_size = page * 16;
	coro->stack = mmap(0, coro->stack_size, PROT_READ | PROT_WRITE | PROT_EXEC,
			   MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);

	if (coro->stack == MAP_FAILED) {
		tnt_raise(LoggedError, :ER_MEMORY_ISSUE,
			  sizeof(coro->stack_size),
			  "mmap", "coro stack");
	}

	(void) VALGRIND_STACK_REGISTER(coro->stack, coro->stack + coro->stack_size);

	coro_create(&coro->ctx, f, data, coro->stack, coro->stack_size);
}

void
tarantool_coro_destroy(struct tarantool_coro *coro)
{
	if (coro->stack != NULL && coro->stack != MAP_FAILED)
		munmap(coro->stack, coro->stack_size);
}
