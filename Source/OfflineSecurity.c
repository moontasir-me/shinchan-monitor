#include "NativeSensors.h"
#include <sandbox.h>
#include <stdio.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

// Process-local Seatbelt restriction. This does not modify the Mac's firewall,
// network configuration, or other applications. No profile can be supplied by users.
// macOS marks this API deprecated; if unavailable or denied we fail closed.
bool sm_offline_start(char *message, int capacity) {
    char *error = NULL;
    int result = sandbox_init("(version 1)(allow default)(deny network*)",0,&error);
    if(result != 0 && message && capacity > 0) {
        snprintf(message,(size_t)capacity,"%s",error ? error : "Network restriction unavailable");
    }
    if(error) sandbox_free_error(error);
    return result == 0;
}
static bool blocked(int result, int error) { return result == -1 && (error == EPERM || error == EACCES); }
bool sm_offline_verify(void) {
    // Test only IPv4/IPv6 loopback. No external hosts, DNS lookups, or web requests.
    for(int v6=0;v6<2;v6++) {
        struct sockaddr_in v4={.sin_len=sizeof(v4),.sin_family=AF_INET,.sin_port=htons(49162),.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
        struct sockaddr_in6 v6addr={.sin6_len=sizeof(v6addr),.sin6_family=AF_INET6,.sin6_port=htons(49162),.sin6_addr=IN6ADDR_LOOPBACK_INIT};
        const struct sockaddr *address=v6?(const struct sockaddr*)&v6addr:(const struct sockaddr*)&v4;
        socklen_t size=v6?sizeof(v6addr):sizeof(v4);
        int fd=socket(v6?AF_INET6:AF_INET,SOCK_STREAM,0);
        if(fd==-1) { if(errno==EPERM||errno==EACCES)continue;return false; }
        int r=connect(fd,address,size),e=errno;
        close(fd);if(!blocked(r,e))return false;
        fd=socket(v6?AF_INET6:AF_INET,SOCK_DGRAM,0);
        if(fd==-1) { if(errno==EPERM||errno==EACCES)continue;return false; }
        r=(int)sendto(fd,"offline-test",12,0,address,size);e=errno;
        if(!blocked(r,e)){close(fd);return false;}
        r=bind(fd,address,size);e=errno;close(fd);
        if(!blocked(r,e))return false;
    }
    return true;
}
