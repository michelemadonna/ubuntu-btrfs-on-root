#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define MAX_INPUT_DEVICES 64
#define MAX_COMBINATION_KEYS 8

#define CONFIG_FILE_NEW "/etc/snapshot-menu.conf"
#define CONFIG_FILE_OLD "/etc/snapshot-menu.conf"

#define CONFIG_VARIABLE_PRIMARY  "EVLISTENER_KEYS"
#define CONFIG_VARIABLE_FALLBACK "SNAPSHOT_MENU_KEYS"

#define DEFAULT_COMBINATION "ALT"

#define MARKER_FILE "/run/snapshot-menu-requested"
#define PID_FILE    "/run/snapshot-key-listener.pid"

#define SCAN_INTERVAL_NS 25000000L

#define BITS_PER_LONG (sizeof(unsigned long) * 8)
#define BIT_WORD(bit) ((bit) / BITS_PER_LONG)
#define BIT_MASK(bit) (1UL << ((bit) % BITS_PER_LONG))
#define KEY_BITMAP_LONGS (BIT_WORD(KEY_MAX) + 1)

enum key_requirement_type {
    REQUIRE_SINGLE,
    REQUIRE_EITHER
};

struct key_requirement {
    enum key_requirement_type type;
    unsigned int first;
    unsigned int second;
};

struct input_device {
    int fd;
};

struct key_name {
    const char *name;
    unsigned int code;
};

static struct input_device devices[MAX_INPUT_DEVICES];
static struct key_requirement requirements[MAX_COMBINATION_KEYS];
static size_t requirement_count;
static volatile sig_atomic_t running = 1;

static const struct key_name key_names[] = {
    { "ESC",        KEY_ESC },
    { "ESCAPE",     KEY_ESC },

    { "1",          KEY_1 },
    { "2",          KEY_2 },
    { "3",          KEY_3 },
    { "4",          KEY_4 },
    { "5",          KEY_5 },
    { "6",          KEY_6 },
    { "7",          KEY_7 },
    { "8",          KEY_8 },
    { "9",          KEY_9 },
    { "0",          KEY_0 },

    { "A",          KEY_A },
    { "B",          KEY_B },
    { "C",          KEY_C },
    { "D",          KEY_D },
    { "E",          KEY_E },
    { "F",          KEY_F },
    { "G",          KEY_G },
    { "H",          KEY_H },
    { "I",          KEY_I },
    { "J",          KEY_J },
    { "K",          KEY_K },
    { "L",          KEY_L },
    { "M",          KEY_M },
    { "N",          KEY_N },
    { "O",          KEY_O },
    { "P",          KEY_P },
    { "Q",          KEY_Q },
    { "R",          KEY_R },
    { "S",          KEY_S },
    { "T",          KEY_T },
    { "U",          KEY_U },
    { "V",          KEY_V },
    { "W",          KEY_W },
    { "X",          KEY_X },
    { "Y",          KEY_Y },
    { "Z",          KEY_Z },

    { "ENTER",      KEY_ENTER },
    { "RETURN",     KEY_ENTER },
    { "SPACE",      KEY_SPACE },
    { "TAB",        KEY_TAB },
    { "BACKSPACE",  KEY_BACKSPACE },
    { "DELETE",     KEY_DELETE },
    { "INSERT",     KEY_INSERT },

    { "UP",         KEY_UP },
    { "DOWN",       KEY_DOWN },
    { "LEFT",       KEY_LEFT },
    { "RIGHT",      KEY_RIGHT },
    { "HOME",       KEY_HOME },
    { "END",        KEY_END },
    { "PAGEUP",     KEY_PAGEUP },
    { "PAGEDOWN",   KEY_PAGEDOWN },

    { "F1",         KEY_F1 },
    { "F2",         KEY_F2 },
    { "F3",         KEY_F3 },
    { "F4",         KEY_F4 },
    { "F5",         KEY_F5 },
    { "F6",         KEY_F6 },
    { "F7",         KEY_F7 },
    { "F8",         KEY_F8 },
    { "F9",         KEY_F9 },
    { "F10",        KEY_F10 },
    { "F11",        KEY_F11 },
    { "F12",        KEY_F12 },

    { "LEFTALT",    KEY_LEFTALT },
    { "LALT",       KEY_LEFTALT },
    { "RIGHTALT",   KEY_RIGHTALT },
    { "RALT",       KEY_RIGHTALT },

    { "LEFTCTRL",   KEY_LEFTCTRL },
    { "LCTRL",      KEY_LEFTCTRL },
    { "RIGHTCTRL",  KEY_RIGHTCTRL },
    { "RCTRL",      KEY_RIGHTCTRL },

    { "LEFTSHIFT",  KEY_LEFTSHIFT },
    { "LSHIFT",     KEY_LEFTSHIFT },
    { "RIGHTSHIFT", KEY_RIGHTSHIFT },
    { "RSHIFT",     KEY_RIGHTSHIFT },

    { "LEFTMETA",   KEY_LEFTMETA },
    { "LMETA",      KEY_LEFTMETA },
    { "LEFTSUPER",  KEY_LEFTMETA },
    { "LSUPER",     KEY_LEFTMETA },

    { "RIGHTMETA",  KEY_RIGHTMETA },
    { "RMETA",      KEY_RIGHTMETA },
    { "RIGHTSUPER", KEY_RIGHTMETA },
    { "RSUPER",     KEY_RIGHTMETA },

    { NULL, 0 }
};

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

static char *trim(char *text)
{
    char *end;

    while (*text != '\0' &&
           isspace((unsigned char)*text)) {
        text++;
    }

    if (*text == '\0')
        return text;

    end = text + strlen(text) - 1;

    while (end > text &&
           isspace((unsigned char)*end)) {
        *end-- = '\0';
    }

    return text;
}

static void uppercase(char *text)
{
    while (*text != '\0') {
        *text = (char)toupper((unsigned char)*text);
        text++;
    }
}

static void remove_optional_quotes(char *text)
{
    size_t length;

    length = strlen(text);

    if (length < 2)
        return;

    if ((text[0] == '"' && text[length - 1] == '"') ||
        (text[0] == '\'' && text[length - 1] == '\'')) {

        memmove(text, text + 1, length - 2);
        text[length - 2] = '\0';
    }
}

static bool read_config_value(
    const char *config_path,
    const char *variable,
    char *result,
    size_t result_size)
{
    FILE *file;
    char line[512];

    file = fopen(config_path, "re");

    if (file == NULL)
        return false;

    while (fgets(line, sizeof(line), file) != NULL) {
        char *name;
        char *value;
        char *equals;
        char *comment;

        name = trim(line);

        if (*name == '\0' || *name == '#')
            continue;

        equals = strchr(name, '=');

        if (equals == NULL)
            continue;

        *equals = '\0';

        value = trim(equals + 1);
        name = trim(name);

        if (strcmp(name, variable) != 0)
            continue;

        /*
         * Remove comments only when the value is not quoted.
         */
        if (*value != '"' && *value != '\'') {
            comment = strchr(value, '#');

            if (comment != NULL)
                *comment = '\0';
        }

        value = trim(value);
        remove_optional_quotes(value);
        value = trim(value);

        if (*value == '\0') {
            fclose(file);
            return false;
        }

        if (strlen(value) >= result_size) {
            fclose(file);
            return false;
        }

        strcpy(result, value);
        fclose(file);
        return true;
    }

    fclose(file);
    return false;
}

static bool load_combination_string(
    char *result,
    size_t result_size)
{
    const char *paths[] = {
        CONFIG_FILE_NEW,
        CONFIG_FILE_OLD,
        NULL
    };

    size_t index;

    for (index = 0; paths[index] != NULL; index++) {
        if (read_config_value(
                paths[index],
                CONFIG_VARIABLE_PRIMARY,
                result,
                result_size)) {
            return true;
        }

        if (read_config_value(
                paths[index],
                CONFIG_VARIABLE_FALLBACK,
                result,
                result_size)) {
            return true;
        }
    }

    if (strlen(DEFAULT_COMBINATION) >= result_size)
        return false;

    strcpy(result, DEFAULT_COMBINATION);
    return true;
}

static bool lookup_single_key(
    const char *name,
    unsigned int *code)
{
    size_t index;

    for (index = 0;
         key_names[index].name != NULL;
         index++) {

        if (strcmp(name, key_names[index].name) == 0) {
            *code = key_names[index].code;
            return true;
        }
    }

    return false;
}

static bool add_single_requirement(unsigned int code)
{
    if (requirement_count >= MAX_COMBINATION_KEYS)
        return false;

    requirements[requirement_count].type =
        REQUIRE_SINGLE;

    requirements[requirement_count].first = code;
    requirements[requirement_count].second = code;

    requirement_count++;
    return true;
}

static bool add_either_requirement(
    unsigned int first,
    unsigned int second)
{
    if (requirement_count >= MAX_COMBINATION_KEYS)
        return false;

    requirements[requirement_count].type =
        REQUIRE_EITHER;

    requirements[requirement_count].first = first;
    requirements[requirement_count].second = second;

    requirement_count++;
    return true;
}

static bool parse_key_token(char *token)
{
    unsigned int code;

    token = trim(token);
    uppercase(token);

    if (strncmp(token, "KEY_", 4) == 0)
        token += 4;

    if (strcmp(token, "ALT") == 0 ||
        strcmp(token, "OPTION") == 0) {

        return add_either_requirement(
            KEY_LEFTALT,
            KEY_RIGHTALT
        );
    }

    if (strcmp(token, "CTRL") == 0 ||
        strcmp(token, "CONTROL") == 0) {

        return add_either_requirement(
            KEY_LEFTCTRL,
            KEY_RIGHTCTRL
        );
    }

    if (strcmp(token, "SHIFT") == 0) {
        return add_either_requirement(
            KEY_LEFTSHIFT,
            KEY_RIGHTSHIFT
        );
    }

    if (strcmp(token, "SUPER") == 0 ||
        strcmp(token, "META") == 0 ||
        strcmp(token, "COMMAND") == 0 ||
        strcmp(token, "CMD") == 0) {

        return add_either_requirement(
            KEY_LEFTMETA,
            KEY_RIGHTMETA
        );
    }

    if (!lookup_single_key(token, &code))
        return false;

    return add_single_requirement(code);
}

static bool parse_combination(char *combination)
{
    char *save_pointer = NULL;
    char *token;

    requirement_count = 0;

    token = strtok_r(combination, "+", &save_pointer);

    while (token != NULL) {
        if (!parse_key_token(token))
            return false;

        token = strtok_r(NULL, "+", &save_pointer);
    }

    return requirement_count > 0;
}

static bool device_supports_event_keys(int fd)
{
    unsigned long event_bits[BIT_WORD(EV_MAX) + 1];

    memset(event_bits, 0, sizeof(event_bits));

    if (ioctl(
            fd,
            EVIOCGBIT(0, sizeof(event_bits)),
            event_bits
        ) < 0) {
        return false;
    }

    return test_bit(event_bits, EV_KEY);
}

static bool device_supports_required_key(int fd)
{
    unsigned long key_bits[KEY_BITMAP_LONGS];
    size_t index;

    memset(key_bits, 0, sizeof(key_bits));

    if (ioctl(
            fd,
            EVIOCGBIT(EV_KEY, sizeof(key_bits)),
            key_bits
        ) < 0) {
        return false;
    }

    for (index = 0;
         index < requirement_count;
         index++) {

        if (test_bit(
                key_bits,
                requirements[index].first)) {
            return true;
        }

        if (requirements[index].type == REQUIRE_EITHER &&
            test_bit(
                key_bits,
                requirements[index].second)) {
            return true;
        }
    }

    return false;
}

static void open_input_device(unsigned int number)
{
    char path[64];
    int fd;

    if (number >= MAX_INPUT_DEVICES)
        return;

    if (devices[number].fd >= 0)
        return;

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
        return;

    if (!device_supports_event_keys(fd) ||
        !device_supports_required_key(fd)) {

        close(fd);
        return;
    }

    devices[number].fd = fd;
}

static void scan_input_devices(void)
{
    unsigned int index;

    for (index = 0;
         index < MAX_INPUT_DEVICES;
         index++) {

        open_input_device(index);
    }
}

static void close_input_device(unsigned int index)
{
    if (index >= MAX_INPUT_DEVICES)
        return;

    if (devices[index].fd >= 0)
        close(devices[index].fd);

    devices[index].fd = -1;
}

static bool read_device_state(
    unsigned int index,
    unsigned long *state)
{
    if (index >= MAX_INPUT_DEVICES)
        return false;

    if (devices[index].fd < 0)
        return false;

    memset(
        state,
        0,
        sizeof(unsigned long) * KEY_BITMAP_LONGS
    );

    if (ioctl(
            devices[index].fd,
            EVIOCGKEY(
                sizeof(unsigned long) *
                KEY_BITMAP_LONGS
            ),
            state
        ) < 0) {

        /*
         * ENODEV means that the input device disappeared.
         */
        if (errno == ENODEV ||
            errno == ENXIO ||
            errno == EBADF) {
            close_input_device(index);
        }

        return false;
    }

    return true;
}

static bool key_is_pressed_on_any_device(unsigned int code)
{
    unsigned int index;
    unsigned long state[KEY_BITMAP_LONGS];

    for (index = 0;
         index < MAX_INPUT_DEVICES;
         index++) {

        if (devices[index].fd < 0)
            continue;

        if (!read_device_state(index, state))
            continue;

        if (test_bit(state, code))
            return true;
    }

    return false;
}

static bool requirement_is_satisfied(
    const struct key_requirement *requirement)
{
    if (key_is_pressed_on_any_device(
            requirement->first)) {
        return true;
    }

    if (requirement->type == REQUIRE_EITHER &&
        key_is_pressed_on_any_device(
            requirement->second)) {
        return true;
    }

    return false;
}

static bool combination_is_pressed(void)
{
    size_t index;

    for (index = 0;
         index < requirement_count;
         index++) {

        if (!requirement_is_satisfied(
                &requirements[index])) {
            return false;
        }
    }

    return true;
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

    if (close(fd) < 0)
        return false;

    return true;
}

static bool write_pid_file(void)
{
    FILE *file;

    file = fopen(PID_FILE, "we");

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
    struct sigaction signal_action;
    struct timespec scan_interval;
    char combination[256];
    unsigned int index;
    int exit_status = 0;

    for (index = 0;
         index < MAX_INPUT_DEVICES;
         index++) {

        devices[index].fd = -1;
    }

    if (!load_combination_string(
            combination,
            sizeof(combination))) {

        fprintf(
            stderr,
            "snapshot-key-listener: "
            "cannot read key combination\n"
        );

        return 1;
    }

    if (!parse_combination(combination)) {
        fprintf(
            stderr,
            "snapshot-key-listener: "
            "invalid key combination\n"
        );

        return 1;
    }

    memset(
        &signal_action,
        0,
        sizeof(signal_action)
    );

    signal_action.sa_handler = handle_signal;
    sigemptyset(&signal_action.sa_mask);

    if (sigaction(SIGTERM, &signal_action, NULL) < 0 ||
        sigaction(SIGINT,  &signal_action, NULL) < 0 ||
        sigaction(SIGHUP,  &signal_action, NULL) < 0) {

        return 1;
    }

    /*
     * Prevent a marker left by a previous listener invocation from
     * activating the menu.
     */
    unlink(MARKER_FILE);

    if (!write_pid_file())
        return 1;

    scan_interval.tv_sec = 0;
    scan_interval.tv_nsec = SCAN_INTERVAL_NS;

    while (running) {
        /*
         * Input devices may appear after the program starts.
         */
        scan_input_devices();

        /*
         * The marker is created only while every configured key is
         * physically reported as pressed by EVIOCGKEY.
         *
         * Releases and autorepeat events are never processed.
         */
        if (combination_is_pressed()) {
            if (!create_marker())
                exit_status = 1;

            break;
        }

        while (nanosleep(
                   &scan_interval,
                   &scan_interval) < 0) {

            if (errno != EINTR) {
                exit_status = 1;
                running = 0;
                break;
            }

            if (!running)
                break;
        }

        scan_interval.tv_sec = 0;
        scan_interval.tv_nsec = SCAN_INTERVAL_NS;
    }

    cleanup();
    return exit_status;
}