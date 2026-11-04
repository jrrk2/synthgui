// atctl: the BIOS at-speed commands from Linux, through /dev/mem (same source as the BIOS).
//   atctl icap <file> | tmmcm m d o cmux cdelay | tfreq | at <cycles> | atread <paths>
//   atctl sweep <m> <d> <o> <cycles> <paths> <cdelay max>: raw counters per capture phase, CSV
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <stdint.h>
#include <generated/csr.h>
volatile uint8_t *csr_map;
#include "cmds/cmd_atspeed.c"
int main(int argc, char **argv) {
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    csr_map = mmap(0, 0x10000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0xf0000000UL);
    if (csr_map == MAP_FAILED) { perror("mmap"); return 1; }
    if (argc < 2) return 2;
    const char *c = argv[1]; char **p = argv + 2; int n = argc - 2;
    if (!strcmp(c, "icap")) {
        int f = open(p[0], O_RDONLY); struct stat st; if (f < 0 || fstat(f, &st)) { perror(p[0]); return 1; }
        char *b = malloc(st.st_size); if (read(f, b, st.st_size) != st.st_size) { perror("read"); return 1; }
        char a[24], w[24]; snprintf(a, sizeof a, "0x%lx", (unsigned long)b); snprintf(w, sizeof w, "%lu", (unsigned long)st.st_size / 4);
        char *q[2] = {a, w}; icap_handler(2, q);
    } else if (!strcmp(c, "tmmcm")) tmmcm_handler(n, p);
    else if (!strcmp(c, "tfreq")) tfreq_handler(n, p);
    else if (!strcmp(c, "at")) at_handler(n, p);
    else if (!strcmp(c, "atread")) atread_handler(n, p);
    else if (!strcmp(c, "status")) printf("status %08lx\n", (unsigned long)atest_status_read());
    else return 2;
    return 0;
}
