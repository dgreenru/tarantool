/*
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
#include <stdio.h>
#include <crope.h>

static inline const char *
str_getn(const char *data, size_t n);

static inline void
str_print(const char *data, size_t n);

static inline void *
mem_alloc(void *data, size_t size);

static inline void
mem_free(void *data, void *ptr);

crope_decl_struct(str, const char, void)
crope_decl_fun(str, const char, void)
crope_define_fun(str, const char, void, str_getn, str_print, mem_alloc, mem_free)

static void
print_title(const char *msg);

static struct rope_str *
test_rope_str_new(char *str);

static void
test_rope_str_extract(struct rope_str *rope, size_t pos);

static void
test_rope_str_append(struct rope_str *rope, char *str);

static void
test_rope_str_prepend(struct rope_str *rope, char *str);

static void
test_rope_str_insert(struct rope_str *rope, size_t pos, char *str);

static void
test_rope_str_remove(struct rope_str *rope, size_t pos, size_t size);

static void
test_crope_str();


int
main()
{
	test_crope_str();
	return EXIT_SUCCESS;
}


static inline const char *
str_getn(const char *data, size_t n)
{
	return data + n;
}

static inline void
str_print(const char *data, size_t n)
{
	printf("%.*s", (int) n, data);
}

static inline void *
mem_alloc(void *data, size_t size)
{
	(void) data;
	return malloc(size);
}

static inline void
mem_free(void *data, void *ptr)
{
	(void) data;
	free(ptr);
}

static void
print_title(const char *msg)
{
	printf("\n#\n");
	printf("# %s test\n", msg);
	printf("#\n\n");
}

static struct rope_str *
test_rope_str_new(char *str)
{
	struct rope_str *rope = rope_str_new(str, strlen(str), NULL);
	rope_str_print_tree("test", rope);
	return rope;
}

static void
test_rope_str_extract(struct rope_str *rope, size_t pos)
{
	printf("extract pos = %zu\n", pos);
	const char *sym = rope_str_extract(rope, pos);
	printf("sym = '%c'\n", *sym);
	rope_str_print_tree("test", rope);
	printf("\n");
}

static void
test_rope_str_append(struct rope_str *rope, char *str)
{
	printf("append str = '%s'\n", str);
	rope_str_append(rope, str, strlen(str));
	rope_str_print_tree("test", rope);
	printf("\n");
}

static void
test_rope_str_prepend(struct rope_str *rope, char *str)
{
	printf("prepend str = '%s'\n", str);
	rope_str_prepend(rope, str, strlen(str));
	rope_str_print_tree("test", rope);
	printf("\n");
}

static void
test_rope_str_insert(struct rope_str *rope, size_t pos, char *str)
{
	printf("insert pos = %zu, str = '%s'\n", pos, str);
	rope_str_insert(rope, pos, str, strlen(str));
	rope_str_print_tree("test", rope);
	printf("\n");
}

static void
test_rope_str_remove(struct rope_str *rope, size_t pos, size_t size)
{
	printf("remove pos = %zu, size = %zu \n", pos, size);
	rope_str_remove(rope, pos, size);
	rope_str_print_tree("test", rope);
	printf("\n");
}

static void
test_crope_str()
{
	struct rope_str *r = test_rope_str_new("who's gonna be");

	print_title("crope str append");
	test_rope_str_append(r, "<Mr.X>");
	test_rope_str_append(r, ", Mr. <black!?!>Black");
	test_rope_str_append(r, ", but they, <know-something-");

	print_title("crope str prepend");
	test_rope_str_prepend(r, "guys all ");

	print_title("crope str insert");
	test_rope_str_insert(r, 9, "five fighting over ");
	test_rope_str_insert(r, 0, "<yes, got got>You got four or ");
	test_rope_str_insert(r, r->size, "special> don't know each other");
	test_rope_str_insert(r, -1, ", so nobody wants to back.");
	test_rope_str_insert(r, r->size - 1, " down");
	test_rope_str_insert(r, -1, "<point-point>");

	print_title("crope str remove");
	test_rope_str_remove(r, 0, 5);
	test_rope_str_remove(r, 0, 9);
	test_rope_str_remove(r, 180, 7);
	test_rope_str_remove(r, 174, -1);
	test_rope_str_remove(r, 58, 7);
	test_rope_str_remove(r, 63, 10);
	test_rope_str_remove(r, 80, 25);
	test_rope_str_remove(r, 131, 1);

	print_title("crope extract");
	test_rope_str_extract(r, 0);
	test_rope_str_extract(r, 5);
	test_rope_str_extract(r, 19);
	test_rope_str_extract(r, 59);
	test_rope_str_extract(r, 130);

	rope_str_delete(r);
}
