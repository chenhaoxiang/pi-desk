import Darwin

// A finite, no-network helper. Node's public net API does not expose getpeereid.
// The bridge passes its connected socket as fd 3 through child_process stdio.
var uid: uid_t = 0
var gid: gid_t = 0
if CommandLine.arguments.count != 1 || getpeereid(3, &uid, &gid) != 0 { exit(1) }
print(uid)
