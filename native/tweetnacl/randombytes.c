/* randombytes() for TweetNaCl, backed by /dev/urandom. */
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>

void randombytes(unsigned char *buf, unsigned long long len)
{
    static int fd = -1;
    while (fd == -1) {
        fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
        if (fd == -1)
            sleep(1);
    }
    while (len > 0) {
        ssize_t n = read(fd, buf, len < 1048576 ? (size_t)len : 1048576);
        if (n < 1) {
            sleep(1);
            continue;
        }
        buf += n;
        len -= n;
    }
}
