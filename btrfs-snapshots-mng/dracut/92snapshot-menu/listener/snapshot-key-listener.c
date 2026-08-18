#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAX_INPUT_DEVICES 64
#define MAX_TRIGGER_KEYS   8
#define MAX_TRIGGER_LENGTH 128

#define MARKER_FILE "/run/snapshot-menu-requested"
#define PID_FILE    "/run/snapshot-key-listener.pid"

#define BITS_PER_LONG (sizeof(unsigned long) * 8U)
#define BIT_WORD(bit) ((bit) / BITS_PER_LONG)
#define BIT_MASK(bit) (1UL << ((bit) % BITS_PER_LONG))
#define KEY_LONGS     (BIT_WORD(KEY_MAX) + 1U)

struct input_device {
    int fd;
    unsigned long supported[KEY_LONGS];
    unsigned long pressed[KEY_LONGS];
};

struct trigger_key {
    unsigned short alternatives[2];
    size_t alternative_count;
};

static struct input_device devices[MAX_INPUT_DEVICES];
static struct trigger_key trigger_keys[MAX_TRIGGER_KEYS];
static size_t trigger_key_count = 0;

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
    if (bit > KEY_MAX)
        return false;

    return (bits[BIT_WORD(bit)] & BIT_MASK(bit)) != 0;
}

static void set_bit(
    unsigned long *bits,
    unsigned int bit,
    bool enabled)
{
    if (bit > KEY_MAX)
        return;

    if (enabled)
        bits[BIT_WORD(bit)] |= BIT_MASK(bit);
    else
        bits[BIT_WORD(bit)] &= ~BIT_MASK(bit);
}

static bool create_marker(void)
{
    int fd;

    fd = open(
        MARKER_FILE,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC,
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

static void uppercase_string(char *value)
{
    unsigned char *cursor;

    for (cursor = (unsigned char *)value;
         *cursor != '\0';
         cursor++) {

        *cursor = (unsigned char)toupper(*cursor);
    }
}

static bool add_single_key(unsigned short key_code)
{
    struct trigger_key *trigger;

    if (trigger_key_count >= MAX_TRIGGER_KEYS)
        return false;

    trigger = &trigger_keys[trigger_key_count++];

    trigger->alternatives[0] = key_code;
    trigger->alternative_count = 1;

    return true;
}

static bool add_alternative_keys(
    unsigned short first,
    unsigned short second)
{
    struct trigger_key *trigger;

    if (trigger_key_count >= MAX_TRIGGER_KEYS)
        return false;

    trigger = &trigger_keys[trigger_key_count++];

    trigger->alternatives[0] = first;
    trigger->alternatives[1] = second;
    trigger->alternative_count = 2;

    return true;
}

static int letter_key_code(char letter)
{
    switch (letter) {
        case 'A': return KEY_A;
        case 'B': return KEY_B;
        case 'C': return KEY_C;
        case 'D': return KEY_D;
        case 'E': return KEY_E;
        case 'F': return KEY_F;
        case 'G': return KEY_G;
        case 'H': return KEY_H;
        case 'I': return KEY_I;
        case 'J': return KEY_J;
        case 'K': return KEY_K;
        case 'L': return KEY_L;
        case 'M': return KEY_M;
        case 'N': return KEY_N;
        case 'O': return KEY_O;
        case 'P': return KEY_P;
        case 'Q': return KEY_Q;
        case 'R': return KEY_R;
        case 'S': return KEY_S;
        case 'T': return KEY_T;
        case 'U': return KEY_U;
        case 'V': return KEY_V;
        case 'W': return KEY_W;
        case 'X': return KEY_X;
        case 'Y': return KEY_Y;
        case 'Z': return KEY_Z;
        default:  return -1;
    }
}

static int digit_key_code(char digit)
{
    switch (digit) {
        case '0': return KEY_0;
        case '1': return KEY_1;
        case '2': return KEY_2;
        case '3': return KEY_3;
        case '4': return KEY_4;
        case '5': return KEY_5;
        case '6': return KEY_6;
        case '7': return KEY_7;
        case '8': return KEY_8;
        case '9': return KEY_9;
        default:  return -1;
    }
}

static int function_key_code(const char *token)
{
    char *end = NULL;
    long number;

    if (token[0] != 'F' || token[1] == '\0')
        return -1;

    errno = 0;
    number = strtol(token + 1, &end, 10);

    if (errno != 0 ||
        end == token + 1 ||
        *end != '\0' ||
        number < 1 ||
        number > 24) {

        return -1;
    }

    return KEY_F1 + (int)number - 1;
}

static bool parse_trigger_token(const char *token)
{
    int key_code;

    /*
     * Generic modifiers accept either left or right key.
     */
    if (strcmp(token, "ALT") == 0 ||
        strcmp(token, "OPTION") == 0) {

        return add_alternative_keys(
            KEY_LEFTALT,
            KEY_RIGHTALT
        );
    }

    if (strcmp(token, "CTRL") == 0 ||
        strcmp(token, "CONTROL") == 0) {

        return add_alternative_keys(
            KEY_LEFTCTRL,
            KEY_RIGHTCTRL
        );
    }

    if (strcmp(token, "SHIFT") == 0) {
        return add_alternative_keys(
            KEY_LEFTSHIFT,
            KEY_RIGHTSHIFT
        );
    }

    if (strcmp(token, "META") == 0 ||
        strcmp(token, "SUPER") == 0 ||
        strcmp(token, "WIN") == 0 ||
        strcmp(token, "COMMAND") == 0 ||
        strcmp(token, "CMD") == 0) {

        return add_alternative_keys(
            KEY_LEFTMETA,
            KEY_RIGHTMETA
        );
    }

    /*
     * Explicit left/right modifiers.
     */
    if (strcmp(token, "LEFTALT") == 0)
        return add_single_key(KEY_LEFTALT);

    if (strcmp(token, "RIGHTALT") == 0)
        return add_single_key(KEY_RIGHTALT);

    if (strcmp(token, "LEFTCTRL") == 0)
        return add_single_key(KEY_LEFTCTRL);

    if (strcmp(token, "RIGHTCTRL") == 0)
        return add_single_key(KEY_RIGHTCTRL);

    if (strcmp(token, "LEFTSHIFT") == 0)
        return add_single_key(KEY_LEFTSHIFT);

    if (strcmp(token, "RIGHTSHIFT") == 0)
        return add_single_key(KEY_RIGHTSHIFT);

    if (strcmp(token, "LEFTMETA") == 0)
        return add_single_key(KEY_LEFTMETA);

    if (strcmp(token, "RIGHTMETA") == 0)
        return add_single_key(KEY_RIGHTMETA);

    /*
     * Named keys.
     */
    if (strcmp(token, "ESC") == 0 ||
        strcmp(token, "ESCAPE") == 0)
        return add_single_key(KEY_ESC);

    if (strcmp(token, "ENTER") == 0 ||
        strcmp(token, "RETURN") == 0)
        return add_single_key(KEY_ENTER);

    if (strcmp(token, "SPACE") == 0)
        return add_single_key(KEY_SPACE);

    if (strcmp(token, "TAB") == 0)
        return add_single_key(KEY_TAB);

    if (strcmp(token, "BACKSPACE") == 0)
        return add_single_key(KEY_BACKSPACE);

    if (strcmp(token, "DELETE") == 0 ||
        strcmp(token, "DEL") == 0)
        return add_single_key(KEY_DELETE);

    if (strcmp(token, "INSERT") == 0 ||
        strcmp(token, "INS") == 0)
        return add_single_key(KEY_INSERT);

    if (strcmp(token, "HOME") == 0)
        return add_single_key(KEY_HOME);

    if (strcmp(token, "END") == 0)
        return add_single_key(KEY_END);

    if (strcmp(token, "PAGEUP") == 0 ||
        strcmp(token, "PGUP") == 0)
        return add_single_key(KEY_PAGEUP);

    if (strcmp(token, "PAGEDOWN") == 0 ||
        strcmp(token, "PGDOWN") == 0)
        return add_single_key(KEY_PAGEDOWN);

    if (strcmp(token, "UP") == 0)
        return add_single_key(KEY_UP);

    if (strcmp(token, "DOWN") == 0)
        return add_single_key(KEY_DOWN);

    if (strcmp(token, "LEFT") == 0)
        return add_single_key(KEY_LEFT);

    if (strcmp(token, "RIGHT") == 0)
        return add_single_key(KEY_RIGHT);

    /*
     * Single letter or digit.
     */
    if (token[0] != '\0' && token[1] == '\0') {
        key_code = letter_key_code(token[0]);

        if (key_code >= 0)
            return add_single_key((unsigned short)key_code);

        key_code = digit_key_code(token[0]);

        if (key_code >= 0)
            return add_single_key((unsigned short)key_code);
    }

    /*
     * Function keys F1-F24.
     */
    key_code = function_key_code(token);

    if (key_code >= 0)
        return add_single_key((unsigned short)key_code);

    return false;
}

static bool parse_trigger(const char *trigger_argument)
{
    char trigger[MAX_TRIGGER_LENGTH];
    char *save_pointer = NULL;
    char *token;
    size_t source_index;
    size_t target_index = 0;

    if (trigger_argument == NULL ||
        trigger_argument[0] == '\0') {

        trigger_argument = "ALT";
    }

    /*
     * Copy the expression while removing whitespace.
     */
    for (source_index = 0;
         trigger_argument[source_index] != '\0';
         source_index++) {

        unsigned char character =
            (unsigned char)trigger_argument[source_index];

        if (isspace(character))
            continue;

        if (target_index + 1 >= sizeof(trigger))
            return false;

        trigger[target_index++] = (char)character;
    }

    trigger[target_index] = '\0';

    if (trigger[0] == '\0')
        return false;

    uppercase_string(trigger);

    token = strtok_r(trigger, "+", &save_pointer);

    while (token != NULL) {
        if (token[0] == '\0')
            return false;

        if (!parse_trigger_token(token))
            return false;

        token = strtok_r(NULL, "+", &save_pointer);
    }

    return trigger_key_count > 0;
}

static bool trigger_key_supported(
    const struct input_device *device,
    const struct trigger_key *trigger)
{
    size_t alternative;

    for (alternative = 0;
         alternative < trigger->alternative_count;
         alternative++) {

        if (test_bit(
                device->supported,
                trigger->alternatives[alternative])) {

            return true;
        }
    }

    return false;
}

static bool device_supports_trigger(
    const struct input_device *device)
{
    size_t index;

    for (index = 0;
         index < trigger_key_count;
         index++) {

        if (!trigger_key_supported(
                device,
                &trigger_keys[index])) {

            return false;
        }
    }

    return true;
}

static bool trigger_key_pressed(
    const struct input_device *device,
    const struct trigger_key *trigger)
{
    size_t alternative;

    for (alternative = 0;
         alternative < trigger->alternative_count;
         alternative++) {

        if (test_bit(
                device->pressed,
                trigger->alternatives[alternative])) {

            return true;
        }
    }

    return false;
}

static bool trigger_is_pressed(
    const struct input_device *device)
{
    size_t index;

    for (index = 0;
         index < trigger_key_count;
         index++) {

        if (!trigger_key_pressed(
                device,
                &trigger_keys[index])) {

            return false;
        }
    }

    return true;
}

static void close_input_device(unsigned int index)
{
    if (index >= MAX_INPUT_DEVICES)
        return;

    if (devices[index].fd >= 0)
        close(devices[index].fd);

    devices[index].fd = -1;

    memset(
        devices[index].supported,
        0,
        sizeof(devices[index].supported)
    );

    memset(
        devices[index].pressed,
        0,
        sizeof(devices[index].pressed)
    );
}

static bool open_input_device(unsigned int number)
{
    char path[64];
    struct input_device candidate;
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
        O_RDONLY | O_NONBLOCK | O_CLOEXEC
    );

    if (fd < 0)
        return false;

    memset(&candidate, 0, sizeof(candidate));
    candidate.fd = fd;

    if (ioctl(
            fd,
            EVIOCGBIT(EV_KEY, sizeof(candidate.supported)),
            candidate.supported
        ) < 0) {

        close(fd);
        return false;
    }

    /*
     * Ignore devices that cannot generate the complete trigger.
     * This prevents combining keys from unrelated devices.
     */
    if (!device_supports_trigger(&candidate)) {
        close(fd);
        return false;
    }

    if (ioctl(
            fd,
            EVIOCGKEY(sizeof(candidate.pressed)),
            candidate.pressed
        ) < 0) {

        memset(
            candidate.pressed,
            0,
            sizeof(candidate.pressed)
        );
    }

    devices[number] = candidate;

    /*
     * Detect a trigger already being held when the listener starts.
     */
    return trigger_is_pressed(&devices[number]);
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
        if (errno == EAGAIN || errno == EINTR)
            return false;

        close_input_device(index);
        return false;
    }

    if (bytes_read == 0) {
        close_input_device(index);
        return false;
    }

    event_count =
        (size_t)bytes_read / sizeof(struct input_event);

    for (event_index = 0;
         event_index < event_count;
         event_index++) {

        const struct input_event *event =
            &events[event_index];

        if (event->type != EV_KEY)
            continue;

        if (event->code > KEY_MAX)
            continue;

        /*
         * EV_KEY:
         *
         *   0 = released
         *   1 = pressed
         *   2 = autorepeat
         */
        if (event->value == 0) {
            set_bit(
                devices[index].pressed,
                event->code,
                false
            );
        } else if (event->value == 1 ||
                   event->value == 2) {

            set_bit(
                devices[index].pressed,
                event->code,
                true
            );
        }

        /*
         * Evaluate only after an initial press or autorepeat.
         */
        if (event->value != 1 &&
            event->value != 2) {

            continue;
        }

        if (trigger_is_pressed(&devices[index]))
            return true;
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

int main(int argc, char *argv[])
{
    struct pollfd poll_fds[MAX_INPUT_DEVICES];
    unsigned int device_indexes[MAX_INPUT_DEVICES];
    struct sigaction signal_action;
    const char *trigger_argument;
    unsigned int index;
    nfds_t poll_count;
    int poll_result;
    int exit_status = EXIT_SUCCESS;

    trigger_argument = argc >= 2 ? argv[1] : "ALT";

    if (!parse_trigger(trigger_argument)) {
        fprintf(
            stderr,
            "snapshot-key-listener: invalid trigger: %s\n",
            trigger_argument
        );

        return EXIT_FAILURE;
    }

    for (index = 0;
         index < MAX_INPUT_DEVICES;
         index++) {

        devices[index].fd = -1;
    }

    memset(&signal_action, 0, sizeof(signal_action));

    signal_action.sa_handler = handle_signal;
    sigemptyset(&signal_action.sa_mask);

    if (sigaction(
            SIGTERM,
            &signal_action,
            NULL
        ) < 0 ||
        sigaction(
            SIGINT,
            &signal_action,
            NULL
        ) < 0 ||
        sigaction(
            SIGHUP,
            &signal_action,
            NULL
        ) < 0) {

        return EXIT_FAILURE;
    }

    if (!write_pid_file())
        return EXIT_FAILURE;

    while (running) {
        /*
         * Devices may appear after the listener starts.
         */
        if (scan_input_devices()) {
            if (!create_marker())
                exit_status = EXIT_FAILURE;

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

            exit_status = EXIT_FAILURE;
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

            device_index = device_indexes[index];

            if (poll_fds[index].revents &
                (POLLERR | POLLHUP | POLLNVAL)) {

                close_input_device(device_index);
                continue;
            }

            if (poll_fds[index].revents & POLLIN) {
                if (process_input_device(device_index)) {
                    if (!create_marker())
                        exit_status = EXIT_FAILURE;

                    running = 0;
                    break;
                }
            }
        }
    }

    cleanup();
    return exit_status;
}
