## Memory Allocator Performance Analysis

On the fragmentation workload, **ptmalloc2** was the worst performer both in terms of fragmentation ratio and allocation rate. Surprisingly, **jemalloc's** allocation rate was much better than that of **tcmalloc** (nearly 2x better). I was skeptical about this result.

On the other hand, the RSS (Resident Set Size) bloat measure was negative for jemalloc because the fragmentation workload wasn't really writing to any of the allocated objects. While jemalloc uses `mmap` for allocating virtual address space, the returned addresses are only mapped to physical memory upon writes.

For security reasons, any memory region returned by the kernel for private and anonymous memory map operations must be zeroed to provide complete isolation between processes. It is possible that the physical pages mapped to the virtual address space of the current process may have been owned by some other process in the past.

Given that most processes create anonymous memory maps but seldom use all of it, the kernel uses a special read-only physical page full of zeros called the **zero page** (or zero folio). This avoids the cost of zeroing at the time of allocation and defers it until the time the process actually writes to these pages. Whenever writes do happen, minor page faults are generated to allocate physical pages. Until this time, the RSS used by the process doesn't grow.

To workaround this problem, I added a write operation via `memcpy` for a fixed 256 B sequence for both the small allocation (256 B) and the large allocation (16384 B). By forcing writes to happen via `memcpy`, physical pages would be mapped to the virtual memory of the process. This would be a more accurate reflection of real-world workloads as well. After this, the jemalloc allocation rate was reduced to 50%.

Still, I was surprised why tcmalloc's allocation rate was still lower than jemalloc. I wondered about all the other logical pages for the large allocation done by jemalloc. There was an option to zero all mmap-ed pages in jemalloc. Upon enabling that, jemalloc became really slow. This was only meant for debugging, but it helped me understand the cost of zeroing.

I wondered whether tcmalloc was pre-faulting some of the pages prior to usage by the program that I wrote. After reading about tcmalloc's internals, I found out that tcmalloc would allocate runs of pages (called a **span**) and then carve it up into slices of desired object sizes. It maintains a free list of objects in its middle-end which is size-class specific.

In order to support efficient iteration over the free list, the carved objects are represented using internal data structures that add pointers in the free list (a singly linked list). This addition of pointers would touch the allocated 4 KiB virtual pages, thus pre-faulting the pages (minor faults). This would lead to an eager allocation of physical memory before the program performs any writes on the objects.

This was verified by running a test program doing allocations on a schedule with `strace`. The `perf stat` command was used to count the number of minor page faults for validation of our theory. However, this didn't turn out to be the smoking gun. There was no way to change some of the tcmalloc tunables without re-building it with a different set of compilation flags.

From an earlier `perf record`, I could find the hot paths in tcmalloc's code which were consuming a lot of CPU cycles. From `strace`, I could see that tcmalloc was using `sbrk` which shouldn't have happened. Then I realized later that we were using an earlier version of tcmalloc (4.5.9) which was still using `sbrk` for sysmalloc. Luckily, there is an option (`TCMALLOC_SKIP_SBRK=1`) to force tcmalloc to only use `mmap`, and after turning it on, it led to further perf improvements.

### ptmalloc2 Discussions

Why is ptmalloc2 so slow? What is the bottleneck for performance? I observed a high amount of CPU usage in the kernel space. Specific parameters like `M_TRIM_THRESHOLD` and `M_TOP_PAD` were TBD, as the heap was being grown very frequently for the large allocations.

Whenever the heap was grown, an `mprotect` syscall was also happening which used to take time because of higher contention on the `osq/rwsem`. Upon setting `MALLOC_TOP_PAD_` (noting the underscore at the end of the environment variable name), the performance of ptmalloc2 improved a lot.

The heap was being grown frequently due to the small allocations. Debugging this was a pain on RHEL primarily because RHEL doesn't provide debug binaries for glibc in a straightforward way. You need to first enroll your RHEL machine to an existing subscription in order to setup the required repositories for running `debuginfo-install`. Eventually, I gave up on it because of running RHEL in a sort of air-gapped environment.

I enabled debug builds for my program and then used `addr2line` to convert the hex addresses in my toy program to find that these `mprotect` calls were indeed coming from the `malloc` calls for the 16 KiB objects. This required understanding how ptmalloc2 worked as a best-fit allocator. After reading implementation details and running test programs with `strace`, I developed a better intuition.

Where is the `sysmalloc` call coming from? I ran the program in a single-threaded mode to discard the possibility of arena contention. It was obvious that the top chunk on the active heap was depleted and didn't have enough memory to accommodate the 16 KiB request.

Whenever the application requests memory via `malloc`, the request size is classified into a bin. If there is no arena, a new one is created along with a new heap. An arena is a collection of heaps linked together (only the latest one is active). The thread-cache (tcache) stores one singly linked list per bin with a maximum of 64 bins.

A chunk is an object which is a wrapper over the original allocation request. The thread-level caching construct minimizes lock contention by providing a per-thread lockless fast allocation path. When objects are freed, if they are small enough ($\le$ 1024 B), they are placed into one of the tcache bins. Unfortunately, large objects bypass the thread cache entirely.

ptmalloc2 maintains a group of free lists organized by chunk size (request size + metadata + padding) to provide faster best-fit allocations. The chunk sizes are classified into fast bins, unsorted bins, and large bins. If the chunk size is within 16 B - 80 B, the freed chunk goes into a fast bin. This provides a fast path for small requests while causing higher fragmentation. Whenever chunks are freed, they are typically placed in unsorted bins first.
