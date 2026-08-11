#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_INPUT_DEVICES 64

#define MARKER_FILE "/run/snapshot-menu-requested"
#define PID_FILE    "/run/snapshot-key-listener.pid"

#define BITS_PER_LONG (sizeof(unsigned long) * 8)
#define BIT_WORD(bit) ((bit) / BITS_PER_LONG)
#define BIT_MASK(bit) (1UL << ((bit) % BITS_PER_LONG))

struct input_device {
    int fd;
};

static struct input_device devices[MAX_INPUT_DEVICES];
static volatile sig_atomic_t running = 1;

static void handle_signal(int signal_number)
{
    (void)signal_number;
    running = 0;
}

static bool test_bit(
    const unsigned long *bits,
    unsigned int bit)
{
    return (bits[BIT_WORD(bit)] & BIT_MASK(bit)) != 0;
}

static bool create_marker(void)
{
    int fd;

    fd = open(
        MARKER_FILE,
        O_WRONLY |
        O_CREAT |
        O_TRUNC |
        O_CLOEXEC,
        0600
    );

    if (fd < 0)
        return false;

    close(fd);
    return true;
}

static bool write_pid_file(void)
{
    FILE *file;

    file = fopen(PID_FILE, "w");

    if (file == NULL)
        return false;

    if (fprintf(file, "%ld\n", (long)getpid()) < 0) {
        fclose(file);
        unlink(PID_FILE);
        return false;
    }

    if (fclose(file) != 0) {
        unlink(PID_FILE);
        return false;
    }

    return true;
}

static bool device_supports_alt(int fd)
{
    unsigned long key_bits[BIT_WORD(KEY_MAX) + 1];

    memset(key_bits, 0, sizeof(key_bits));

    if (ioctl(
            fd,
            EVIOCGBIT(EV_KEY, sizeof(key_bits)),
            key_bits
        ) < 0) {
        return false;
    }

    return test_bit(key_bits, KEY_LEFTALT) ||
           test_bit(key_bits, KEY_RIGHTALT);
}

static bool alt_is_currently_pressed(int fd)
{
    unsigned long key_state[BIT_WORD(KEY_MAX) + 1];

    memset(key_state, 0, sizeof(key_state));

    if (ioctl(
            fd,
            EVIOCGKEY(sizeof(key_state)),
            key_state
        ) < 0) {
        return false;
    }

    return test_bit(key_state, KEY_LEFTALT) ||
           test_bit(key_state, KEY_RIGHTALT);
}

static bool open_input_device(unsigned int number)
{
    char path[64];
    int fd;

    if (number >= MAX_INPUT_DEVICES)
        return false;

    if (devices[number].fd >= 0)
        return false;

    snprintf(
        path,
        sizeof(path),
        "/dev/input/event%u",
        number
    );

    fd = open(
        path,
        O_RDONLY |
        O_NONBLOCK |
        O_CLOEXEC
    );

    if (fd < 0)
        return false;

    if (!device_supports_alt(fd)) {
        close(fd);
        return false;
    }

    devices[number].fd = fd;

    /*
     * Alt may already be held when the event device appears.
     */
    return alt_is_currently_pressed(fd);
}

static bool scan_input_devices(void)
{
    unsigned int index;

    for (index = 0;
         index < MAX_INPUT_DEVICES;
         index++) {

        if (open_input_device(index))
            return true;
    }

    return false;
}

static void close_input_device(unsigned int index)
{
    if (index >= MAX_INPUT_DEVICES)
        return;

    if (devices[index].fd >= 0)
        close(devices[index].fd);

    devices[index].fd = -1;
}

static bool process_input_device(unsigned int index)
{
    struct input_event events[16];
    ssize_t bytes_read;
    size_t event_count;
    size_t event_index;

    bytes_read = read(
        devices[index].fd,
        events,
        sizeof(events)
    );

    if (bytes_read < 0) {
        if (errno == EAGAIN ||
            errno == EINTR) {
            return false;
        }

        close_input_device(index);
        return false;
    }

    if (bytes_read == 0) {
        close_input_device(index);
        return false;
    }

    event_count =
        (size_t)bytes_read /
        sizeof(struct input_event);

    for (event_index = 0;
         event_index < event_count;
         event_index++) {

        const struct input_event *event =
            &events[event_index];

        if (event->type != EV_KEY)
            continue;

        /*
         * EV_KEY values:
         *
         *   0 = released
         *   1 = initial press
         *   2 = autorepeat
         *
         * Trigger only on the initial Alt press.
         */
        if (event->value != 1)
            continue;

        if (event->code == KEY_LEFTALT ||
            event->code == KEY_RIGHTALT) {
            return true;
        }
    }

    return false;
}

static void cleanup(void)
{
    unsigned int index;

    for (index = 0;
         index < MAX_INPUT_DEVICES;
         index++) {

        close_input_device(index);
    }

    unlink(PID_FILE);
}

int main(void)
{
    struct pollfd poll_fds[MAX_INPUT_DEVICES];
    unsigned int device_indexes[MAX_INPUT_DEVICES];
    struct sigaction signal_action;
    unsigned int index;
    nfds_t poll_count;
    int poll_result;
    int exit_status = 0;

    for (index = 0;
         index < MAX_INPUT_DEVICES;
         index++) {

        devices[index].fd = -1;
    }

    memset(
        &signal_action,
        0,
        sizeof(signal_action)
    );

    signal_action.sa_handler = handle_signal;

    sigemptyset(&signal_action.sa_mask);

    sigaction(SIGTERM, &signal_action, NULL);
    sigaction(SIGINT,  &signal_action, NULL);
    sigaction(SIGHUP,  &signal_action, NULL);

    if (!write_pid_file())
        return 1;

    while (running) {
        /*
         * Input event devices may appear after this process starts.
         * Rescan every 100 milliseconds.
         */
        if (scan_input_devices()) {
            if (!create_marker())
                exit_status = 1;

            break;
        }

        poll_count = 0;

        for (index = 0;
             index < MAX_INPUT_DEVICES;
             index++) {

            if (devices[index].fd < 0)
                continue;

            poll_fds[poll_count].fd =
                devices[index].fd;

            poll_fds[poll_count].events =
                POLLIN;

            poll_fds[poll_count].revents =
                0;

            device_indexes[poll_count] = index;

            poll_count++;
        }

        poll_result = poll(
            poll_fds,
            poll_count,
            100
        );

        if (poll_result < 0) {
            if (errno == EINTR)
                continue;

            exit_status = 1;
            break;
        }

        if (poll_result == 0)
            continue;

        for (index = 0;
             index < poll_count;
             index++) {

            unsigned int device_index;

            if (poll_fds[index].revents == 0)
                continue;

            device_index =
                device_indexes[index];

            if (poll_fds[index].revents &
                (POLLERR |
                 POLLHUP |
                 POLLNVAL)) {

                close_input_device(device_index);
                continue;
            }

            if (poll_fds[index].revents & POLLIN) {
                if (process_input_device(device_index)) {
                    if (!create_marker())
                        exit_status = 1;

                    running = 0;
                    break;
                }
            }
        }
    }

    cleanup();
    return exit_status;
}