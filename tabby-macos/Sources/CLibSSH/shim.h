// libssh (https://www.libssh.org, LGPL 2.1), from Homebrew's `libssh` on macOS.
#include <libssh/libssh.h>
#include <libssh/callbacks.h>
#include <libssh/sftp.h>
#include <libssh/server.h>  // ssh_send_keepalive (client-side too)
