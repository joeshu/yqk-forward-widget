#include <signal.h>

// CPython is embedded with install_signal_handlers=0. Restore only its usual
// default SIGPIPE policy; never replace a pre-existing custom SDK handler.
// Returns: -1 error, 0 already ignored, 1 installed, 2 custom handler preserved.
static inline int HostProtectDefaultBrokenPipe(void) {
    struct sigaction current;
    if(sigaction(SIGPIPE, 0, &current)!=0)return -1;
    if(current.sa_handler==SIG_IGN)return 0;
    if(current.sa_handler!=SIG_DFL)return 2;
    struct sigaction ignored={0};ignored.sa_handler=SIG_IGN;sigemptyset(&ignored.sa_mask);
    return sigaction(SIGPIPE,&ignored,0)==0?1:-1;
}
