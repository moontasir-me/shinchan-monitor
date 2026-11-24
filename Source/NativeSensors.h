#ifndef SHINCHAN_NATIVE_SENSORS_H
#define SHINCHAN_NATIVE_SENSORS_H
#include <stdint.h>
#include <stdbool.h>
typedef struct {
    uint64_t cpuTicks;
    uint64_t startedTicks;
    uint64_t bytesRead;
    uint64_t bytesWritten;
} SMProcessSample;
int sm_list_pids(int32_t *pids, int capacity);
bool sm_process_sample(int32_t pid, SMProcessSample *sample);
int sm_process_path(int32_t pid, char *buffer, int size);
int sm_process_name(int32_t pid, char *buffer, int size);
uint32_t sm_smc_open(void);
void sm_smc_close(uint32_t connection);
double sm_smc_temperature(uint32_t connection, const char *key);
#endif
