//
//  SensorsBridge.h
//  SysTech
//
//  Low-level access to the System Management Controller (SMC) and the
//  IOHID temperature sensors. Both are undocumented Apple interfaces, so they
//  live in C behind a small plain-C API.
//

#ifndef SensorsBridge_h
#define SensorsBridge_h

#include <stdbool.h>
#include <stdint.h>

/// Opens a connection to AppleSMC. Safe to call repeatedly.
bool smc_open(void);
void smc_close(void);

/// Number of keys the SMC exposes (value of the `#KEY` key).
uint32_t smc_key_count(void);

/// Writes the four character key at `index` into `out` (NUL terminated).
bool smc_key_at_index(uint32_t index, char out[5]);

/// Reads `key` and decodes it to a double. Supports flt, sp*, fp*, ui*, si*.
bool smc_read_double(const char *key, double *out);

typedef struct {
    char name[64];
    double value;
} hid_sensor_reading;

/// Reads every IOHID temperature sensor (Apple Silicon). Returns count written.
int hid_read_temperatures(hid_sensor_reading *out, int max);

#endif /* SensorsBridge_h */
