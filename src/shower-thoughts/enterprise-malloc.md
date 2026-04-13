# Enterprise Malloc

If you've ever used FPGA toolchains, you know they crash. Sometimes immediately, sometimes 12 hours into a build. Sometimes it's an internal assert, but usually just a common-or-garden segfault. They also claim to support reproducible builds, yet sometimes re-running with the same inputs doesn't crash, curious 🤔

[@mei@donotsta.re](https://donotsta.re/notice/AyOlmskSNl7OEE5kFk) is a real straight shooter with upper management written all over them, and they have this innovative (dare I say disruptive?) solution to enterprise software that crashes when you sneeze. I'm posting this here partly because I admire it as a piece of art and partly so I can find it next time I need it. The file name is `enterprise_malloc.c`.

```c
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdlib.h>
#define FREE_DELAY 100000

static void *free_delay_queue[FREE_DELAY];
static int free_delay_pos;
static void (*orig_free)(void *);
static void *(*orig_malloc)(size_t);
static pthread_mutex_t free_delay_mutex = PTHREAD_MUTEX_INITIALIZER;

void free(void *ptr) {
	if (!ptr)
		return;
	pthread_mutex_lock(&free_delay_mutex);
	if (!orig_free)
		orig_free = dlsym(RTLD_NEXT, "free");
	orig_free(free_delay_queue[free_delay_pos]);
	free_delay_queue[free_delay_pos] = ptr;
	free_delay_pos++;
	free_delay_pos %= FREE_DELAY;
	pthread_mutex_unlock(&free_delay_mutex);
}

void *malloc(size_t sz) {
	pthread_mutex_lock(&free_delay_mutex);
	if (!orig_malloc)
		orig_malloc = dlsym(RTLD_NEXT, "malloc");
	pthread_mutex_unlock(&free_delay_mutex);
	return orig_malloc (sz * 2 + 0x100);
}
```

The call `dlsym(RTLD_NEXT, ...);` is similar to the GNU linker `--wrap` directive, but for dynamic linking. If you're not familiar with linker wrapping, it's like `RTLD_NEXT` but for static linking. This code shims all dynamically-linked calls to `malloc` and `free`, adding its own logic but still deferring to the standard library versions for the actual implementation.

The differences between Enterprise Malloc™ and the version you may be familiar with from the ISO C standard are:

* When you `free` a pointer, it actually `free`s the pointer you passed `FREE_DELAY` calls ago. This is a crude form of quarantining and reduces the blast radius of use-after-free errors.

* When you call `malloc`, it doubles the size and adds 256 bytes. This converts out-of-bounds accesses into **Bonus Data**.

There are some improvements that would make this more enterprise grade, like adding similar hacks to `calloc` and `realloc` (the latter probably best implemented as `malloc(); memcpy(); free();`). Still, this version is elegant in its minimalism. For example, the static variables `free_delay_queue` and `free_delay_pos` may at first glance appear uninitialised, but a close reading of the C standard will show that it guarantees zero initialisation for static-storage-duration variables without an explicit initialiser, and this technique saves valuable bytes in the source code file.
