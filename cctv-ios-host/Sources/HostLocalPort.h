#ifndef HOST_LOCAL_PORT_H
#define HOST_LOCAL_PORT_H
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
// 1 reachable, 0 positively refused, -1 unknown. A timeout is not proof that
// the listener was released. Call off the UI thread.
static inline int HostLocalPortState(int port) {
    if(port<1||port>65535)return -1;
    int fd=socket(AF_INET,SOCK_STREAM,0);if(fd<0)return -1;
    int flags=fcntl(fd,F_GETFL,0);
    if(flags<0||fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0){close(fd);return -1;}
    struct sockaddr_in address={0};address.sin_family=AF_INET;
#ifdef __APPLE__
    address.sin_len=sizeof(address);
#endif
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);address.sin_port=htons((unsigned short)port);
    int result=connect(fd,(struct sockaddr *)&address,sizeof(address)),error=errno;
    if(result<0&&(error==EINPROGRESS||error==EWOULDBLOCK)){
        fd_set writes;FD_ZERO(&writes);
        if(fd>=FD_SETSIZE){close(fd);return -1;}
        FD_SET(fd,&writes);struct timeval timeout={0,300000};
        result=select(fd+1,0,&writes,0,&timeout);
        if(result<=0){close(fd);return -1;}
        socklen_t length=sizeof(error);if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&length)<0){close(fd);return -1;}
    }else if(result==0)error=0;
    close(fd);return error==0?1:(error==ECONNREFUSED?0:-1);
}
#endif
