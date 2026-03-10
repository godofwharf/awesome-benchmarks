#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main() {
    printf("Starting allocations. Check strace for mmap/brk calls...\n");

    // We store pointers to prevent the compiler from
    // optimizing the loop away entirely.
    void* ptrs[10000];
    void* ptrs2[10000];

    for (int i = 0; i < 10000; i++) {
        ptrs[i] = malloc(256);
	ptrs2[i] = malloc(16384);

	printf("Iteration %d: Allocated 256B at %p\n", i, ptrs[i]);
	printf("Iteration %d: Allocated 16384B at %p\n", i, ptrs2[i]);
	usleep(10000);
        if (ptrs[i] == NULL || ptrs2[i] == NULL) {
            fprintf(stderr, "Malloc failed at iteration %d\n", i);
            return 1;
        }
	free(ptrs2[i]);

        printf("Iteration %d: Freed 16384B at %p\n", i, ptrs2[i]);
        //usleep(10000);
    }

    return 0;
}
