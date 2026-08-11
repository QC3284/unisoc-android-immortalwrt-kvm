#define _FILE_OFFSET_BITS 64

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BUFFER_SIZE (1024 * 1024)

static void fail(const char *operation)
{
    fprintf(stderr, "sparse-writer: %s: %s\n", operation, strerror(errno));
    exit(1);
}

static int all_zero(const unsigned char *buffer, size_t length)
{
    size_t i;
    for (i = 0; i < length; ++i) {
        if (buffer[i] != 0)
            return 0;
    }
    return 1;
}

static void write_all(int fd, const unsigned char *buffer, size_t length)
{
    while (length != 0) {
        ssize_t written = write(fd, buffer, length);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            fail("write");
        }
        buffer += written;
        length -= (size_t)written;
    }
}

int main(int argc, char **argv)
{
    unsigned char *buffer;
    off_t logical_size = 0;
    int output;

    if (argc != 2) {
        fprintf(stderr, "usage: %s OUTPUT\n", argv[0]);
        return 2;
    }
    output = open(argv[1], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (output < 0)
        fail("open output");
    buffer = malloc(BUFFER_SIZE);
    if (buffer == NULL)
        fail("allocate buffer");

    for (;;) {
        ssize_t count = read(STDIN_FILENO, buffer, BUFFER_SIZE);
        if (count == 0)
            break;
        if (count < 0) {
            if (errno == EINTR)
                continue;
            fail("read");
        }
        if (all_zero(buffer, (size_t)count)) {
            if (lseek(output, count, SEEK_CUR) < 0)
                fail("seek over zero block");
        } else {
            write_all(output, buffer, (size_t)count);
        }
        logical_size += count;
    }
    if (ftruncate(output, logical_size) < 0)
        fail("set logical size");
    if (fsync(output) < 0)
        fail("fsync");
    if (close(output) < 0)
        fail("close");
    free(buffer);
    return 0;
}
