//
//  SensorsBridge.c
//  SysTech
//

#include "SensorsBridge.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <string.h>

// MARK: - SMC

#define SMC_KERNEL_INDEX     2
#define SMC_CMD_READ_BYTES   5
#define SMC_CMD_READ_INDEX   8
#define SMC_CMD_READ_KEYINFO 9

// Layout must match the kernel's SMCParamStruct (80 bytes).
typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} smc_version;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} smc_plimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} smc_key_info;

typedef struct {
    uint32_t key;
    smc_version vers;
    smc_plimit pLimitData;
    smc_key_info keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} smc_param;

_Static_assert(sizeof(smc_param) == 80, "smc_param layout mismatch");

static io_connect_t smc_conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static void fourcc_str(uint32_t v, char out[5]) {
    out[0] = (char)(v >> 24);
    out[1] = (char)(v >> 16);
    out[2] = (char)(v >> 8);
    out[3] = (char)v;
    out[4] = '\0';
}

bool smc_open(void) {
    if (smc_conn) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return false;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &smc_conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        smc_conn = 0;
        return false;
    }
    return true;
}

void smc_close(void) {
    if (smc_conn) {
        IOServiceClose(smc_conn);
        smc_conn = 0;
    }
}

static bool smc_call(smc_param *in, smc_param *out) {
    if (!smc_open()) return false;
    size_t out_size = sizeof(smc_param);
    kern_return_t kr = IOConnectCallStructMethod(smc_conn, SMC_KERNEL_INDEX, in, sizeof(smc_param), out, &out_size);
    return kr == KERN_SUCCESS && out->result == 0;
}

// Key info never changes at runtime, so cache it to halve the SMC calls per read.
typedef struct {
    uint32_t key;
    uint32_t size;
    uint32_t type;
} smc_info_cache_entry;

#define SMC_INFO_CACHE_SIZE 512
static smc_info_cache_entry smc_info_cache[SMC_INFO_CACHE_SIZE];
static int smc_info_cache_count = 0;

static bool smc_key_info_cached(uint32_t key, uint32_t *size, uint32_t *type) {
    for (int i = 0; i < smc_info_cache_count; i++) {
        if (smc_info_cache[i].key == key) {
            *size = smc_info_cache[i].size;
            *type = smc_info_cache[i].type;
            return true;
        }
    }

    smc_param in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (!smc_call(&in, &out)) return false;

    *size = out.keyInfo.dataSize;
    *type = out.keyInfo.dataType;
    if (smc_info_cache_count < SMC_INFO_CACHE_SIZE) {
        smc_info_cache[smc_info_cache_count++] = (smc_info_cache_entry){key, *size, *type};
    }
    return true;
}

static bool smc_read_raw(const char *key, uint32_t *type, uint32_t *size, uint8_t bytes[32]) {
    if (strlen(key) != 4) return false;

    uint32_t data_size = 0, data_type = 0;
    if (!smc_key_info_cached(fourcc(key), &data_size, &data_type)) return false;
    if (data_size == 0 || data_size > 32) return false;

    smc_param in = {0}, out = {0};
    in.key = fourcc(key);
    in.keyInfo.dataSize = data_size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (!smc_call(&in, &out)) return false;

    *type = data_type;
    *size = data_size;
    memcpy(bytes, out.bytes, 32);
    return true;
}

uint32_t smc_key_count(void) {
    double count = 0;
    return smc_read_double("#KEY", &count) ? (uint32_t)count : 0;
}

bool smc_key_at_index(uint32_t index, char out[5]) {
    smc_param in = {0}, result = {0};
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    if (!smc_call(&in, &result)) return false;
    fourcc_str(result.key, out);
    return true;
}

static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool smc_read_double(const char *key, double *out) {
    uint32_t type = 0, size = 0;
    uint8_t b[32];
    if (!smc_read_raw(key, &type, &size, b)) return false;

    char t[5];
    fourcc_str(type, t);

    // Apple Silicon: little-endian IEEE float.
    if (strcmp(t, "flt ") == 0 && size == 4) {
        float f;
        memcpy(&f, b, 4);
        *out = f;
        return true;
    }

    // Big-endian integers.
    if (strncmp(t, "ui", 2) == 0 || strncmp(t, "si", 2) == 0) {
        uint64_t v = 0;
        for (uint32_t i = 0; i < size && i < 8; i++) v = (v << 8) | b[i];
        if (t[0] == 's') {
            int shift = 64 - (int)size * 8;
            *out = (double)((int64_t)(v << shift) >> shift);
        } else {
            *out = (double)v;
        }
        return true;
    }

    // Fixed point: fpXY (unsigned) / spXY (signed), 2 bytes big-endian, Y fraction bits (hex digit).
    if ((t[0] == 'f' || t[0] == 's') && t[1] == 'p' && size == 2) {
        int frac = hex_digit(t[3]);
        if (frac < 0) return false;
        uint16_t raw = (uint16_t)((b[0] << 8) | b[1]);
        double v = t[0] == 's' ? (double)(int16_t)raw : (double)raw;
        *out = v / (double)(1 << frac);
        return true;
    }

    return false;
}

// MARK: - IOHID temperature sensors (private API)

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)

static IOHIDEventSystemClientRef hid_client(void) {
    static IOHIDEventSystemClientRef client = NULL;
    if (client) return client;

    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NULL;

    int page = 0xff00, usage = 5; // AppleVendor / TemperatureSensor
    CFNumberRef page_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usage_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {page_num, usage_num};
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match);
    CFRelease(page_num);
    CFRelease(usage_num);
    return client;
}

int hid_read_temperatures(hid_sensor_reading *out, int max) {
    IOHIDEventSystemClientRef client = hid_client();
    if (!client) return 0;

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return 0;

    int n = 0;
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count && n < max; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);

        if (name && CFGetTypeID(name) == CFStringGetTypeID() && event) {
            if (CFStringGetCString((CFStringRef)name, out[n].name, sizeof(out[n].name), kCFStringEncodingUTF8)) {
                out[n].value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
                n++;
            }
        }
        if (event) CFRelease(event);
        if (name) CFRelease(name);
    }
    CFRelease(services);
    return n;
}
