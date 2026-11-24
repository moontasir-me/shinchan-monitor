#include "NativeSensors.h"
#include <IOKit/IOKitLib.h>
#include <libproc.h>
#include <sys/resource.h>
#include <string.h>
#include <math.h>

int sm_list_pids(int32_t *pids, int capacity) { return proc_listallpids(pids,capacity*(int)sizeof(int32_t)); }
bool sm_process_sample(int32_t pid, SMProcessSample *sample) {
    struct rusage_info_v4 value={0};
    if(proc_pid_rusage(pid,RUSAGE_INFO_V4,(rusage_info_t*)&value)!=0)return false;
    sample->cpuTicks=value.ri_user_time+value.ri_system_time;
    sample->startedTicks=value.ri_proc_start_abstime;
    sample->bytesRead=value.ri_diskio_bytesread;
    sample->bytesWritten=value.ri_diskio_byteswritten;
    return true;
}
int sm_process_path(int32_t pid,char *buffer,int size){return proc_pidpath(pid,buffer,(uint32_t)size);}
int sm_process_name(int32_t pid,char *buffer,int size){return proc_name(pid,buffer,(uint32_t)size);}

// Read-only AppleSMC user-client messages. No key-writing operation is exposed.
typedef struct { uint8_t major,minor,build,reserved; uint16_t release; } SMVersion;
typedef struct { uint16_t version,length; uint32_t cpu,gpu,memory; } SMLimits;
typedef struct { uint32_t size,type; uint8_t attributes; } SMKeyInfo;
typedef struct {
    uint32_t key;
    SMVersion version;
    SMLimits limits;
    SMKeyInfo info;
    uint8_t result,status,command;
    uint32_t argument;
    uint8_t bytes[32];
} SMMessage;
_Static_assert(sizeof(SMMessage)==80,"SMC message layout must be 80 bytes");
static uint32_t fourcc(const char *s){return ((uint32_t)(uint8_t)s[0]<<24)|((uint32_t)(uint8_t)s[1]<<16)|((uint32_t)(uint8_t)s[2]<<8)|(uint8_t)s[3];}
uint32_t sm_smc_open(void){
    io_service_t service=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
    if(!service)return 0;
    io_connect_t connection=0;
    kern_return_t result=IOServiceOpen(service,mach_task_self(),0,&connection);IOObjectRelease(service);
    return result==KERN_SUCCESS?connection:0;
}
void sm_smc_close(uint32_t connection){if(connection)IOServiceClose(connection);}
static bool sm_call(uint32_t connection,SMMessage *input,SMMessage *output){
    size_t size=sizeof(*output);
    return IOConnectCallStructMethod(connection,2,input,sizeof(*input),output,&size)==KERN_SUCCESS && size==sizeof(*output) && output->result==0;
}
double sm_smc_temperature(uint32_t connection,const char *key){
    if(!connection||!key||strlen(key)!=4)return NAN;
    SMMessage request={0},response={0};request.key=fourcc(key);request.command=9;
    if(!sm_call(connection,&request,&response)||response.info.size==0||response.info.size>32)return NAN;
    uint32_t type=response.info.type;request.info=response.info;request.command=5;
    memset(&response,0,sizeof response);if(!sm_call(connection,&request,&response))return NAN;
    double value=NAN;
    if(type==fourcc("flt ")){float f;memcpy(&f,response.bytes,sizeof f);value=f;}
    else if(type==fourcc("sp78")){int16_t n=(int16_t)(((uint16_t)response.bytes[0]<<8)|response.bytes[1]);value=(double)n/256;}
    return isfinite(value)&&value>=5&&value<=130?value:NAN;
}
