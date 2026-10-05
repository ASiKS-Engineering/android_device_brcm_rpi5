/*
 * hailo_service - vendor daemon that supervises the Hailo-8 accelerator.
 *
 * Current scope (bring-up):
 *   - read /vendor/etc/hailo/hailo_service.conf
 *   - verify the firmware files the kernel driver requests
 *   - wait for /dev/hailo0 (created by the hailo_pci kernel driver)
 *   - query driver version and device properties through the driver ioctl API
 *   - publish the result in the property vendor.hailo.status
 *
 * vendor.hailo.status values:
 *   starting | fw_missing | waiting_device | fw_not_loaded | error | ready | stopped
 *
 * The HailoRT inference loop is added on top of this once libhailort is packaged.
 *
 * Optional runtime probe: once the driver reports ready, libhailort (runtime_library in the
 * config) is loaded with dlopen, a vdevice is created and the model is configured on it.
 * The result is published in vendor.hailo.rt_status:
 *   not_probed | lib_missing | lib_error | device_error | model_missing | model_error | ok
 * libhailort is loaded at runtime, so the image builds and boots without it.
 */

#include <android/log.h>
#include <ctype.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/system_properties.h>
#include <unistd.h>

#define TAG "hailo_service"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

#define CONF_PATH "/vendor/etc/hailo/hailo_service.conf"
#define DEVICE_PATH "/dev/hailo0"
#define STATUS_PROP "vendor.hailo.status"
#define RT_STATUS_PROP "vendor.hailo.rt_status"
#define POLL_INTERVAL_SEC 5
#define HEARTBEAT_EVERY_POLLS 12
#define VALUE_LEN 256
#define FULL_PATH_LEN 640

/*
 * ABI of the hailo_pci character device (drivers/hailo/common/hailo_ioctl_common.h).
 * The kernel header packs these structures with #pragma pack(1) and encodes
 * sizeof() into the ioctl numbers, so the layout must match exactly.
 */
struct hailo_driver_info {
    uint32_t major_version;
    uint32_t minor_version;
    uint32_t revision_version;
} __attribute__((packed));

struct hailo_device_properties {
    uint16_t desc_max_page_size;
    int32_t board_type;
    int32_t allocation_mode;
    int32_t dma_type;
    uint64_t dma_engines_count;
    uint8_t is_fw_loaded;
} __attribute__((packed));

_Static_assert(sizeof(struct hailo_driver_info) == 12, "hailo_driver_info ABI mismatch");
_Static_assert(sizeof(struct hailo_device_properties) == 23, "hailo_device_properties ABI mismatch");

#define HAILO_GENERAL_IOCTL_MAGIC 'g'
#define HAILO_QUERY_DEVICE_PROPERTIES _IOW(HAILO_GENERAL_IOCTL_MAGIC, 1, struct hailo_device_properties)
#define HAILO_QUERY_DRIVER_INFO _IOW(HAILO_GENERAL_IOCTL_MAGIC, 2, struct hailo_driver_info)

enum probe_result {
    PROBE_OK,
    PROBE_FW_NOT_LOADED,
    PROBE_ERROR,
};

/*
 * Minimal view of the libhailort C API (hailort/libhailort/include/hailo/hailort.h, v4.24.0).
 * hailo_status is a plain int enum (0 == HAILO_SUCCESS); all handles are opaque pointers.
 */
#define HRT_SUCCESS 0
#define HRT_MAX_NETWORK_GROUPS 8

struct hrt_version {
    uint32_t major;
    uint32_t minor;
    uint32_t revision;
};

struct hrt_api {
    int (*get_library_version)(struct hrt_version*);
    const char* (*get_status_message)(int);
    int (*create_vdevice)(void* params, void** vdevice);
    int (*release_vdevice)(void* vdevice);
    int (*create_hef_file)(void** hef, const char* file_name);
    int (*release_hef)(void* hef);
    int (*configure_vdevice)(void* vdevice, void* hef, void* params, void** network_groups,
                             size_t* number_of_network_groups);
};

struct config {
    char firmware_dir[VALUE_LEN];
    char firmware_files[VALUE_LEN];
    char model_path[VALUE_LEN];
    char runtime_library[VALUE_LEN];
};

static volatile sig_atomic_t g_running = 1;
static char g_status[PROP_VALUE_MAX] = "";

static void handle_signal(int signo) {
    (void)signo;
    g_running = 0;
}

static void set_status(const char* status) {
    if (strcmp(status, g_status) == 0) {
        return;
    }
    if (__system_property_set(STATUS_PROP, status) != 0) {
        LOGW("failed to set %s=%s", STATUS_PROP, status);
    }
    snprintf(g_status, sizeof(g_status), "%s", status);
    LOGI("status -> %s", status);
}

static void set_rt_status(const char* status) {
    if (__system_property_set(RT_STATUS_PROP, status) != 0) {
        LOGW("failed to set %s=%s", RT_STATUS_PROP, status);
    }
    LOGI("rt_status -> %s", status);
}

static char* trim(char* s) {
    while (isspace((unsigned char)*s)) {
        s++;
    }
    size_t n = strlen(s);
    while (n > 0 && isspace((unsigned char)s[n - 1])) {
        s[--n] = '\0';
    }
    return s;
}

static void load_config(struct config* cfg) {
    snprintf(cfg->firmware_dir, sizeof(cfg->firmware_dir), "%s", "/vendor/firmware/hailo");
    snprintf(cfg->firmware_files, sizeof(cfg->firmware_files), "%s",
             "hailo8_fw.bin,hailo8_board_cfg.bin,hailo8_fw_cfg.bin");
    snprintf(cfg->model_path, sizeof(cfg->model_path), "%s", "/vendor/etc/hailo/models/default.hef");
    snprintf(cfg->runtime_library, sizeof(cfg->runtime_library), "%s", "/vendor/lib64/libhailort.so");

    FILE* f = fopen(CONF_PATH, "re");
    if (f == NULL) {
        LOGW("cannot read %s (%s), using defaults", CONF_PATH, strerror(errno));
        return;
    }

    char line[VALUE_LEN * 2];
    while (fgets(line, sizeof(line), f) != NULL) {
        char* key = trim(line);
        if (*key == '\0' || *key == '#') {
            continue;
        }
        char* eq = strchr(key, '=');
        if (eq == NULL) {
            continue;
        }
        *eq = '\0';
        key = trim(key);
        char* value = trim(eq + 1);

        if (strcmp(key, "firmware_dir") == 0) {
            snprintf(cfg->firmware_dir, sizeof(cfg->firmware_dir), "%s", value);
        } else if (strcmp(key, "firmware_files") == 0) {
            snprintf(cfg->firmware_files, sizeof(cfg->firmware_files), "%s", value);
        } else if (strcmp(key, "model_path") == 0) {
            snprintf(cfg->model_path, sizeof(cfg->model_path), "%s", value);
        } else if (strcmp(key, "runtime_library") == 0) {
            snprintf(cfg->runtime_library, sizeof(cfg->runtime_library), "%s", value);
        }
    }
    fclose(f);
}

/* The first listed file is mandatory (the driver cannot boot the chip without it). */
static bool check_firmware(const struct config* cfg, bool verbose) {
    char list[VALUE_LEN];
    snprintf(list, sizeof(list), "%s", cfg->firmware_files);

    bool mandatory_ok = true;
    int index = 0;
    char* saveptr = NULL;
    for (char* token = strtok_r(list, ",", &saveptr); token != NULL;
         token = strtok_r(NULL, ",", &saveptr), index++) {
        char* name = trim(token);
        char path[FULL_PATH_LEN];
        snprintf(path, sizeof(path), "%s/%s", cfg->firmware_dir, name);

        struct stat st;
        if (stat(path, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 0) {
            if (verbose) {
                LOGI("firmware ok: %s (%lld bytes)", path, (long long)st.st_size);
            }
        } else if (index == 0) {
            mandatory_ok = false;
            if (verbose) {
                LOGE("mandatory firmware missing: %s", path);
            }
        } else if (verbose) {
            LOGW("optional firmware missing: %s", path);
        }
    }
    return mandatory_ok;
}

static enum probe_result probe_device(void) {
    int fd = open(DEVICE_PATH, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        LOGE("open %s failed: %s", DEVICE_PATH, strerror(errno));
        return PROBE_ERROR;
    }

    struct hailo_driver_info info;
    memset(&info, 0, sizeof(info));
    if (ioctl(fd, HAILO_QUERY_DRIVER_INFO, &info) < 0) {
        LOGE("HAILO_QUERY_DRIVER_INFO failed: %s", strerror(errno));
        close(fd);
        return PROBE_ERROR;
    }
    LOGI("driver version %u.%u.%u", info.major_version, info.minor_version, info.revision_version);

    struct hailo_device_properties props;
    memset(&props, 0, sizeof(props));
    if (ioctl(fd, HAILO_QUERY_DEVICE_PROPERTIES, &props) < 0) {
        LOGE("HAILO_QUERY_DEVICE_PROPERTIES failed: %s", strerror(errno));
        close(fd);
        return PROBE_ERROR;
    }
    LOGI("board_type=%d (0 = Hailo-8) dma_engines=%llu desc_max_page_size=%u fw_loaded=%u",
         (int)props.board_type, (unsigned long long)props.dma_engines_count,
         (unsigned)props.desc_max_page_size, (unsigned)props.is_fw_loaded);

    /* Do not keep the device open: an open fd keeps the chip in D0 and blocks rmmod. */
    close(fd);
    return props.is_fw_loaded ? PROBE_OK : PROBE_FW_NOT_LOADED;
}

static bool load_hrt_api(void* lib, struct hrt_api* api) {
#define HRT_LOAD(field, symbol)                                         \
    do {                                                                \
        api->field = dlsym(lib, symbol);                                \
        if (api->field == NULL) {                                       \
            LOGE("libhailort: missing symbol %s", symbol);              \
            return false;                                               \
        }                                                               \
    } while (0)

    HRT_LOAD(get_library_version, "hailo_get_library_version");
    HRT_LOAD(get_status_message, "hailo_get_status_message");
    HRT_LOAD(create_vdevice, "hailo_create_vdevice");
    HRT_LOAD(release_vdevice, "hailo_release_vdevice");
    HRT_LOAD(create_hef_file, "hailo_create_hef_file");
    HRT_LOAD(release_hef, "hailo_release_hef");
    HRT_LOAD(configure_vdevice, "hailo_configure_vdevice");
#undef HRT_LOAD
    return true;
}

/*
 * Loads libhailort, opens a vdevice and configures the model on it. Everything is released
 * again before returning, so the device stays free for other users and for rmmod.
 * The library stays mapped for the lifetime of the process (no dlclose).
 */
static void probe_runtime(const struct config* cfg) {
    if (access(cfg->runtime_library, R_OK) != 0) {
        LOGW("libhailort not installed: %s", cfg->runtime_library);
        set_rt_status("lib_missing");
        return;
    }

    void* lib = dlopen(cfg->runtime_library, RTLD_NOW | RTLD_LOCAL);
    if (lib == NULL) {
        LOGE("dlopen %s failed: %s", cfg->runtime_library, dlerror());
        set_rt_status("lib_error");
        return;
    }

    struct hrt_api api;
    memset(&api, 0, sizeof(api));
    if (!load_hrt_api(lib, &api)) {
        set_rt_status("lib_error");
        return;
    }

    struct hrt_version version;
    memset(&version, 0, sizeof(version));
    if (api.get_library_version(&version) == HRT_SUCCESS) {
        LOGI("libhailort version %u.%u.%u", version.major, version.minor, version.revision);
    }

    void* vdevice = NULL;
    int rc = api.create_vdevice(NULL, &vdevice);
    if (rc != HRT_SUCCESS) {
        LOGE("hailo_create_vdevice failed: %d (%s)", rc, api.get_status_message(rc));
        set_rt_status("device_error");
        return;
    }
    LOGI("vdevice created");

    if (access(cfg->model_path, R_OK) != 0) {
        LOGW("model not found: %s", cfg->model_path);
        api.release_vdevice(vdevice);
        set_rt_status("model_missing");
        return;
    }

    void* hef = NULL;
    rc = api.create_hef_file(&hef, cfg->model_path);
    if (rc != HRT_SUCCESS) {
        LOGE("hailo_create_hef_file(%s) failed: %d (%s)", cfg->model_path, rc,
             api.get_status_message(rc));
        api.release_vdevice(vdevice);
        set_rt_status("model_error");
        return;
    }

    void* network_groups[HRT_MAX_NETWORK_GROUPS];
    size_t group_count = HRT_MAX_NETWORK_GROUPS;
    rc = api.configure_vdevice(vdevice, hef, NULL, network_groups, &group_count);
    if (rc != HRT_SUCCESS) {
        LOGE("hailo_configure_vdevice failed: %d (%s)", rc, api.get_status_message(rc));
        api.release_hef(hef);
        api.release_vdevice(vdevice);
        set_rt_status("model_error");
        return;
    }
    LOGI("model configured: %zu network group(s)", group_count);

    api.release_hef(hef);
    api.release_vdevice(vdevice);
    set_rt_status("ok");
}

int main(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handle_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    set_status("starting");
    set_rt_status("not_probed");

    struct config cfg;
    load_config(&cfg);
    LOGI("config: firmware_dir=%s model_path=%s", cfg.firmware_dir, cfg.model_path);

    if (access(cfg.model_path, R_OK) != 0) {
        LOGW("model not found: %s (inference disabled until a .hef is installed)", cfg.model_path);
    }

    bool fw_ok = check_firmware(&cfg, true);
    bool probed = false;
    bool rt_probed = false;
    unsigned polls = 0;

    while (g_running) {
        fw_ok = check_firmware(&cfg, false);

        if (access(DEVICE_PATH, F_OK) != 0) {
            if (probed) {
                LOGW("%s disappeared", DEVICE_PATH);
            }
            probed = false;
            rt_probed = false;
            set_status(fw_ok ? "waiting_device" : "fw_missing");
        } else if (!probed) {
            switch (probe_device()) {
                case PROBE_OK:
                    probed = true;
                    set_status("ready");
                    break;
                case PROBE_FW_NOT_LOADED:
                    set_status("fw_not_loaded");
                    break;
                case PROBE_ERROR:
                    set_status("error");
                    break;
            }
        }

        if (probed && !rt_probed) {
            rt_probed = true;
            probe_runtime(&cfg);
        }

        if (polls++ % HEARTBEAT_EVERY_POLLS == 0) {
            LOGI("heartbeat status=%s", g_status);
        }
        sleep(POLL_INTERVAL_SEC);
    }

    set_status("stopped");
    return 0;
}
