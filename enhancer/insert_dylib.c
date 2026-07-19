#include <errno.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static void fail(const char *message) {
    fprintf(stderr, "insert_dylib: %s\n", message);
    exit(EXIT_FAILURE);
}

static uint32_t align8(uint32_t value) {
    return (value + 7U) & ~7U;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <dylib-load-path> <thin-arm64-mach-o>\n", argv[0]);
        return EXIT_FAILURE;
    }

    const char *load_path = argv[1];
    const char *binary_path = argv[2];
    size_t load_path_length = strlen(load_path) + 1U;
    if (load_path_length > UINT32_MAX - sizeof(struct dylib_command)) {
        fail("load path is too long");
    }

    int fd = open(binary_path, O_RDWR);
    if (fd < 0) {
        perror("insert_dylib: open");
        return EXIT_FAILURE;
    }

    struct stat file_stat;
    if (fstat(fd, &file_stat) != 0 || file_stat.st_size < (off_t)sizeof(struct mach_header_64)) {
        close(fd);
        fail("invalid input size");
    }

    size_t file_size = (size_t)file_stat.st_size;
    uint8_t *bytes = mmap(NULL, file_size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (bytes == MAP_FAILED) {
        perror("insert_dylib: mmap");
        close(fd);
        return EXIT_FAILURE;
    }

    struct mach_header_64 *header = (struct mach_header_64 *)bytes;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) {
        munmap(bytes, file_size);
        close(fd);
        fail("input must be a thin arm64 Mach-O");
    }

    size_t commands_start = sizeof(*header);
    size_t commands_end = commands_start + header->sizeofcmds;
    if (commands_end > file_size) {
        munmap(bytes, file_size);
        close(fd);
        fail("load-command table exceeds file size");
    }

    uint32_t first_section_offset = UINT32_MAX;
    uint8_t *cursor = bytes + commands_start;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        if ((size_t)(cursor - bytes) + sizeof(struct load_command) > commands_end) {
            munmap(bytes, file_size);
            close(fd);
            fail("truncated load command");
        }

        struct load_command *command = (struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) ||
            (size_t)(cursor - bytes) + command->cmdsize > commands_end) {
            munmap(bytes, file_size);
            close(fd);
            fail("invalid load-command size");
        }

        if (command->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *segment = (struct segment_command_64 *)cursor;
            size_t sections_size = (size_t)segment->nsects * sizeof(struct section_64);
            if (sizeof(*segment) + sections_size > command->cmdsize) {
                munmap(bytes, file_size);
                close(fd);
                fail("invalid section table");
            }
            struct section_64 *sections = (struct section_64 *)(segment + 1);
            for (uint32_t section_index = 0; section_index < segment->nsects;
                 section_index++) {
                uint32_t offset = sections[section_index].offset;
                if (offset != 0 && offset < first_section_offset) {
                    first_section_offset = offset;
                }
            }
        }

        if (command->cmd == LC_LOAD_DYLIB || command->cmd == LC_LOAD_WEAK_DYLIB ||
            command->cmd == LC_REEXPORT_DYLIB || command->cmd == LC_LOAD_UPWARD_DYLIB) {
            struct dylib_command *dylib_command = (struct dylib_command *)cursor;
            uint32_t name_offset = dylib_command->dylib.name.offset;
            if (name_offset < command->cmdsize) {
                const char *existing_path = (const char *)cursor + name_offset;
                size_t maximum_length = command->cmdsize - name_offset;
                if (strnlen(existing_path, maximum_length) < maximum_length &&
                    strcmp(existing_path, load_path) == 0) {
                    printf("Already present: %s\n", load_path);
                    munmap(bytes, file_size);
                    close(fd);
                    return EXIT_SUCCESS;
                }
            }
        }

        cursor += command->cmdsize;
    }

    if ((size_t)(cursor - bytes) != commands_end || first_section_offset == UINT32_MAX) {
        munmap(bytes, file_size);
        close(fd);
        fail("could not determine load-command padding");
    }

    uint32_t new_command_size = align8(
        (uint32_t)(sizeof(struct dylib_command) + load_path_length));
    if (commands_end + new_command_size > first_section_offset) {
        munmap(bytes, file_size);
        close(fd);
        fail("not enough header padding for an additional dylib command");
    }

    for (size_t offset = commands_end; offset < commands_end + new_command_size; offset++) {
        if (bytes[offset] != 0) {
            munmap(bytes, file_size);
            close(fd);
            fail("load-command padding is not empty");
        }
    }

    struct dylib_command *new_command = (struct dylib_command *)(bytes + commands_end);
    memset(new_command, 0, new_command_size);
    new_command->cmd = LC_LOAD_DYLIB;
    new_command->cmdsize = new_command_size;
    new_command->dylib.name.offset = sizeof(struct dylib_command);
    memcpy((uint8_t *)new_command + sizeof(struct dylib_command), load_path,
           load_path_length);

    header->ncmds += 1U;
    header->sizeofcmds += new_command_size;

    if (msync(bytes, file_size, MS_SYNC) != 0) {
        perror("insert_dylib: msync");
        munmap(bytes, file_size);
        close(fd);
        return EXIT_FAILURE;
    }
    if (munmap(bytes, file_size) != 0 || close(fd) != 0) {
        perror("insert_dylib: close");
        return EXIT_FAILURE;
    }

    printf("Inserted %s\n", load_path);
    return EXIT_SUCCESS;
}
