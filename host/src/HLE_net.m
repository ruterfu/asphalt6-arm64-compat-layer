// SystemConfiguration reachability.
//
// The original asks SystemConfiguration for a reachability object and then
// hands it a *guest* callback and a *guest* hostname. Passing either straight
// through makes the host dereference a 32-bit guest address, which is a
// SIGSEGV. The reference is therefore wrapped as an opaque handle, the
// hostname is copied into host memory, and the guest callback is recorded
// rather than handed to the host run loop.

#import "HLE.h"
#import "GuestVM.h"
#import "GuestObjC.h"

#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <CoreFoundation/CoreFoundation.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <sys/time.h>
#import <netdb.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_var.h>
#import <errno.h>
#import <vector>
#import <algorithm>

uint32_t HLEWrapOpaque(GuestVM *vm, void *p);
void *HLEUnwrapOpaque(GuestVM *vm, uint32_t v);

static SCNetworkReachabilityRef RefFor(GuestVM *vm, gva_t handle) {
    return (SCNetworkReachabilityRef)(uintptr_t)HLEUnwrapOpaque(vm, handle);
}

HLE_DEFINE(hle_SCCreateWithName) {
    NSString *host = GuestReadCString(vm, GuestArg(vm, 1), 1024);
    SCNetworkReachabilityRef ref =
        host.length ? SCNetworkReachabilityCreateWithName(NULL, host.UTF8String) : NULL;
    GuestSetRet(vm, HLEWrapOpaque(vm, (void *)(uintptr_t)ref));
}
HLE_BIND("_SCNetworkReachabilityCreateWithName", hle_SCCreateWithName)

// The local Wi-Fi game asks about the link-local network (169.254.0.0) and
// wants it reachable and direct, not over WWAN; it then looks up en0's IPv4
// address. That reference is answered from the Wi-Fi interface itself.
static uint32_t g_linkLocalRef = 0;

static bool WifiHasIPv4(void) {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list)) return false;
    bool found = false;
    for (struct ifaddrs *i = list; i && !found; i = i->ifa_next)
        found = i->ifa_addr && i->ifa_addr->sa_family == AF_INET && !(i->ifa_flags & IFF_LOOPBACK) &&
                (i->ifa_flags & IFF_UP) && !strcmp(i->ifa_name, "en0");
    freeifaddrs(list);
    return found;
}

HLE_DEFINE(hle_SCCreateWithAddress) {
    // The guest sockaddr lives in emulated memory; a wildcard address is what
    // the game actually asks for when it only wants to know "is there a net".
    struct sockaddr_in guest = {};
    const bool linkLocal = GuestRead(vm, GuestArg(vm, 1), &guest, sizeof(guest)) && guest.sin_family == AF_INET &&
        (ntohl(guest.sin_addr.s_addr) >> 16) == 0xa9fe;
    struct sockaddr_in addr = {};
    addr.sin_len = sizeof(addr);
    addr.sin_family = AF_INET;
    SCNetworkReachabilityRef ref =
        SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&addr);
    const uint32_t handle = HLEWrapOpaque(vm, (void *)(uintptr_t)ref);
    if (linkLocal) g_linkLocalRef = handle;
    GuestSetRet(vm, handle);
}
HLE_BIND("_SCNetworkReachabilityCreateWithAddress", hle_SCCreateWithAddress)

HLE_DEFINE(hle_SCGetFlags) {
    SCNetworkReachabilityRef ref = RefFor(vm, GuestArg(vm, 0));
    gva_t out = GuestArg(vm, 1);
    if (g_linkLocalRef && GuestArg(vm, 0) == g_linkLocalRef) {
        const uint32_t direct = WifiHasIPv4() ?
            (uint32_t)(kSCNetworkReachabilityFlagsReachable | kSCNetworkReachabilityFlagsIsDirect) : 0;
        if (out) GuestWriteU32(vm, out, direct);
        NSLog(@"[local-wifi] link-local reachability flags=%#x", direct);
        GuestSetRet(vm, 1);
        return;
    }
    SCNetworkReachabilityFlags flags = 0;
    BOOL ok = ref ? (SCNetworkReachabilityGetFlags(ref, &flags) == true) : NO;
    if (!ok) {
        // No live reference: report a plain Wi-Fi connection so the game does
        // not sit on its "no network" path forever.
        flags = kSCNetworkReachabilityFlagsReachable;
    }
    if (out) GuestWriteU32(vm, out, (uint32_t)flags);
    GuestSetRet(vm, ok || ref ? 1 : 0);
}
HLE_BIND("_SCNetworkReachabilityGetFlags", hle_SCGetFlags)

// The callback and its context are guest code / guest memory: recording them
// keeps the host from ever jumping into a 32-bit address.
static gva_t g_scCallback = 0;
static gva_t g_scContext = 0;

HLE_DEFINE(hle_SCSetCallback) {
    g_scCallback = GuestArg(vm, 1);
    g_scContext = GuestArg(vm, 2);
    GuestSetRet(vm, 1);
}
HLE_BIND("_SCNetworkReachabilitySetCallback", hle_SCSetCallback)

HLE_DEFINE(hle_SCSchedule) { GuestSetRet(vm, 1); }
HLE_BIND("_SCNetworkReachabilityScheduleWithRunLoop", hle_SCSchedule)

HLE_DEFINE(hle_SCUnschedule) { GuestSetRet(vm, 0); }
HLE_BIND("_SCNetworkReachabilityUnscheduleFromRunLoop", hle_SCUnschedule)

// --- BSD networking --------------------------------------------------------
// The Darwin armv7 sockaddr and fd_set layouts match the host, but their
// addresses do not. Every pointer passed to the kernel is backed by host
// scratch; timeval fields must additionally widen from 32 to 64 bits.
extern void HLESetGuestErrno(GuestVM *vm, int value);

static void NetResult(GuestVM *vm, int64_t result, int savedErrno) {
    if (result < 0) HLESetGuestErrno(vm, savedErrno);
    GuestSetRet(vm, (uint32_t)result);
}

static bool NetRead(GuestVM *vm, gva_t address, void *dst, size_t size) {
    if (!size) return true;
    if (!address || !GuestRead(vm, address, dst, size)) { errno = EFAULT; return false; }
    return true;
}

static bool NetAddress(GuestVM *vm, gva_t address, uint32_t length,
                       std::vector<uint8_t> &bytes) {
    if (length > 256) { errno = EINVAL; return false; }
    bytes.assign(std::max(length, 1u), 0);
    return NetRead(vm, address, bytes.data(), length);
}

HLE_DEFINE(hle_socket) {
    int r = socket((int)GuestArg(vm, 0), (int)GuestArg(vm, 1), (int)GuestArg(vm, 2));
    NetResult(vm, r, errno);
}
HLE_BIND("_socket", hle_socket)

static void NetBindConnect(GuestVM *vm, bool connecting) {
    int fd = (int)GuestArg(vm, 0);
    uint32_t length = GuestArg(vm, 2);
    std::vector<uint8_t> bytes;
    if (!NetAddress(vm, GuestArg(vm, 1), length, bytes)) { NetResult(vm, -1, errno); return; }
    const struct sockaddr *address = (const struct sockaddr *)bytes.data();
    int r = connecting ? connect(fd, address, (socklen_t)length)
                       : bind(fd, address, (socklen_t)length);
    NetResult(vm, r, errno);
}
HLE_DEFINE(hle_bind) { NetBindConnect(vm, false); }
HLE_BIND("_bind", hle_bind)
HLE_DEFINE(hle_connect) { NetBindConnect(vm, true); }
HLE_BIND("_connect", hle_connect)
HLE_DEFINE(hle_listen) {
    int r = listen((int)GuestArg(vm, 0), (int)GuestArg(vm, 1));
    NetResult(vm, r, errno);
}
HLE_BIND("_listen", hle_listen)

// accept/getpeername/getsockname use an in/out socklen_t*, which is 32-bit on
// both sides. Preserve the caller's capacity and return the kernel's length.
static void NetGetAddress(GuestVM *vm, int operation) {
    int fd = (int)GuestArg(vm, 0);
    gva_t out = GuestArg(vm, 1), lenOut = GuestArg(vm, 2);
    uint32_t capacity = 0;
    if (out && (!lenOut || !GuestRead(vm, lenOut, &capacity, 4))) {
        NetResult(vm, -1, EFAULT); return;
    }
    uint8_t bytes[256] = {};
    socklen_t length = std::min(capacity, (uint32_t)sizeof(bytes));
    struct sockaddr *address = out ? (struct sockaddr *)bytes : nullptr;
    int r;
    if (operation == 0) r = accept(fd, address, out ? &length : nullptr);
    else if (operation == 1) r = getsockname(fd, address, out ? &length : nullptr);
    else r = getpeername(fd, address, out ? &length : nullptr);
    int saved = errno;
    if (r >= 0 && out) {
        size_t n = std::min((size_t)capacity, std::min((size_t)length, sizeof(bytes)));
        if (n) GuestWrite(vm, out, bytes, n);
        GuestWriteU32(vm, lenOut, length);
    }
    NetResult(vm, r, saved);
}
HLE_DEFINE(hle_accept) { NetGetAddress(vm, 0); }
HLE_BIND("_accept", hle_accept)
HLE_DEFINE(hle_getsockname) { NetGetAddress(vm, 1); }
HLE_BIND("_getsockname", hle_getsockname)
HLE_DEFINE(hle_getpeername) { NetGetAddress(vm, 2); }
HLE_BIND("_getpeername", hle_getpeername)

static bool NetTimeoutOption(int level, int option) {
    return level == SOL_SOCKET && (option == SO_RCVTIMEO || option == SO_SNDTIMEO);
}

HLE_DEFINE(hle_setsockopt) {
    int fd = (int)GuestArg(vm, 0), level = (int)GuestArg(vm, 1);
    int option = (int)GuestArg(vm, 2);
    gva_t value = GuestArg(vm, 3);
    uint32_t length = GuestArg(vm, 4);
    if (length > (1u << 20)) { NetResult(vm, -1, EINVAL); return; }
    std::vector<uint8_t> bytes(std::max(length, 1u), 0);
    if (!NetRead(vm, value, bytes.data(), length)) { NetResult(vm, -1, errno); return; }
    struct timeval tv = {};
    const void *hostValue = value ? bytes.data() : nullptr;
    socklen_t hostLength = length;
    if (NetTimeoutOption(level, option) && length == 8) {
        int32_t fields[2]; memcpy(fields, bytes.data(), sizeof(fields));
        tv.tv_sec = fields[0]; tv.tv_usec = fields[1];
        hostValue = &tv; hostLength = sizeof(tv);
    }
    int r = setsockopt(fd, level, option, hostValue, hostLength);
    NetResult(vm, r, errno);
}
HLE_BIND("_setsockopt", hle_setsockopt)

HLE_DEFINE(hle_getsockopt) {
    int fd = (int)GuestArg(vm, 0), level = (int)GuestArg(vm, 1);
    int option = (int)GuestArg(vm, 2);
    gva_t value = GuestArg(vm, 3), lenOut = GuestArg(vm, 4);
    uint32_t capacity = 0;
    if (!NetRead(vm, lenOut, &capacity, 4)) { NetResult(vm, -1, errno); return; }
    if (capacity > (1u << 20)) { NetResult(vm, -1, EINVAL); return; }
    bool timeout = NetTimeoutOption(level, option);
    std::vector<uint8_t> bytes(std::max((size_t)capacity, sizeof(struct timeval)), 0);
    socklen_t length = timeout ? sizeof(struct timeval) : capacity;
    int r = getsockopt(fd, level, option, value ? bytes.data() : nullptr, &length);
    int saved = errno;
    if (r == 0) {
        if (timeout) {
            struct timeval tv = {}; memcpy(&tv, bytes.data(), sizeof(tv));
            int32_t fields[2] = {(int32_t)tv.tv_sec, (int32_t)tv.tv_usec};
            memcpy(bytes.data(), fields, sizeof(fields)); length = sizeof(fields);
        }
        if (value && capacity) GuestWrite(vm, value, bytes.data(), std::min(capacity, (uint32_t)length));
        GuestWriteU32(vm, lenOut, length);
    }
    NetResult(vm, r, saved);
}
HLE_BIND("_getsockopt", hle_getsockopt)

HLE_DEFINE(hle_select) {
    int nfds = (int)GuestArg(vm, 0);
    gva_t readOut = GuestArg(vm, 1), writeOut = GuestArg(vm, 2);
    gva_t exceptOut = GuestArg(vm, 3), timeout = GuestArg(vm, 4);
    fd_set reads = {}, writes = {}, exceptions = {};
    if (nfds < 0 || nfds > FD_SETSIZE) { NetResult(vm, -1, EINVAL); return; }
    if ((readOut && !NetRead(vm, readOut, &reads, sizeof(reads))) ||
        (writeOut && !NetRead(vm, writeOut, &writes, sizeof(writes))) ||
        (exceptOut && !NetRead(vm, exceptOut, &exceptions, sizeof(exceptions)))) {
        NetResult(vm, -1, errno); return;
    }
    struct timeval tv = {};
    if (timeout) {
        int32_t fields[2];
        if (!NetRead(vm, timeout, fields, sizeof(fields))) { NetResult(vm, -1, errno); return; }
        tv.tv_sec = fields[0]; tv.tv_usec = fields[1];
    }
    int r = select(nfds, readOut ? &reads : nullptr, writeOut ? &writes : nullptr,
                   exceptOut ? &exceptions : nullptr, timeout ? &tv : nullptr);
    int saved = errno;
    if (r >= 0) {
        if (readOut) GuestWrite(vm, readOut, &reads, sizeof(reads));
        if (writeOut) GuestWrite(vm, writeOut, &writes, sizeof(writes));
        if (exceptOut) GuestWrite(vm, exceptOut, &exceptions, sizeof(exceptions));
        // Darwin leaves the timeout unchanged. Do not impose Linux's timeout
        // decrement on a game built against the iOS BSD interface.
    }
    NetResult(vm, r, saved);
}
HLE_BIND("_select", hle_select)

static void NetSend(GuestVM *vm, bool withAddress) {
    int fd = (int)GuestArg(vm, 0), flags = (int)GuestArg(vm, 3);
    gva_t source = GuestArg(vm, 1);
    uint32_t length = GuestArg(vm, 2);
    std::vector<uint8_t> bytes(std::max(length, 1u), 0), address;
    if (!NetRead(vm, source, bytes.data(), length)) { NetResult(vm, -1, errno); return; }
    uint32_t addressLength = withAddress ? GuestArg(vm, 5) : 0;
    gva_t destination = withAddress ? GuestArg(vm, 4) : 0;
    if (withAddress && !NetAddress(vm, destination, addressLength, address)) {
        NetResult(vm, -1, errno); return;
    }
    ssize_t r = withAddress ? sendto(fd, bytes.data(), length, flags,
                                    destination ? (const struct sockaddr *)address.data() : nullptr,
                                    addressLength)
                            : send(fd, bytes.data(), length, flags);
    NetResult(vm, r, errno);
}
HLE_DEFINE(hle_send) { NetSend(vm, false); }
HLE_BIND("_send", hle_send)
HLE_DEFINE(hle_sendto) { NetSend(vm, true); }
HLE_BIND("_sendto", hle_sendto)

static void NetReceive(GuestVM *vm, bool withAddress) {
    int fd = (int)GuestArg(vm, 0), flags = (int)GuestArg(vm, 3);
    gva_t destination = GuestArg(vm, 1);
    uint32_t length = GuestArg(vm, 2);
    gva_t addressOut = withAddress ? GuestArg(vm, 4) : 0;
    gva_t lenOut = withAddress ? GuestArg(vm, 5) : 0;
    uint32_t capacity = 0;
    if (length && !destination) { NetResult(vm, -1, EFAULT); return; }
    if (addressOut && !NetRead(vm, lenOut, &capacity, 4)) { NetResult(vm, -1, errno); return; }
    std::vector<uint8_t> bytes(std::max(length, 1u), 0);
    uint8_t address[256] = {};
    socklen_t addressLength = std::min(capacity, (uint32_t)sizeof(address));
    ssize_t r = withAddress ? recvfrom(fd, bytes.data(), length, flags,
                                      addressOut ? (struct sockaddr *)address : nullptr,
                                      addressOut ? &addressLength : nullptr)
                            : recv(fd, bytes.data(), length, flags);
    int saved = errno;
    if (r >= 0) {
        if (r > 0) GuestWrite(vm, destination, bytes.data(), std::min((size_t)r, (size_t)length));
        if (addressOut) {
            size_t n = std::min((size_t)capacity, std::min((size_t)addressLength, sizeof(address)));
            if (n) GuestWrite(vm, addressOut, address, n);
            GuestWriteU32(vm, lenOut, addressLength);
        }
    }
    NetResult(vm, r, saved);
}
HLE_DEFINE(hle_recv) { NetReceive(vm, false); }
HLE_BIND("_recv", hle_recv)
HLE_DEFINE(hle_recvfrom) { NetReceive(vm, true); }
HLE_BIND("_recvfrom", hle_recvfrom)

HLE_DEFINE(hle_gethostname) {
    gva_t out = GuestArg(vm, 0);
    uint32_t length = GuestArg(vm, 1);
    if (!out && length) { NetResult(vm, -1, EFAULT); return; }
    std::vector<char> bytes(std::max(length, 1u), 0);
    int r = gethostname(bytes.data(), length);
    int saved = errno;
    if (length) GuestWrite(vm, out, bytes.data(), length);
    NetResult(vm, r, saved);
}
HLE_BIND("_gethostname", hle_gethostname)

HLE_DEFINE(hle_inet_addr) {
    NSString *text = GuestReadCString(vm, GuestArg(vm, 0), 256);
    GuestSetRet(vm, text ? inet_addr(text.UTF8String) : INADDR_NONE);
}
HLE_BIND("_inet_addr", hle_inet_addr)
HLE_DEFINE(hle_inet_aton) {
    NSString *text = GuestReadCString(vm, GuestArg(vm, 0), 256);
    gva_t out = GuestArg(vm, 1);
    struct in_addr address = {};
    int r = text && out ? inet_aton(text.UTF8String, &address) : 0;
    if (r) GuestWrite(vm, out, &address, sizeof(address));
    GuestSetRet(vm, r);
}
HLE_BIND("_inet_aton", hle_inet_aton)
HLE_DEFINE(hle_inet_ntoa) {
    struct in_addr address = {GuestArg(vm, 0)};
    char text[INET_ADDRSTRLEN] = {};
    const char *r = inet_ntop(AF_INET, &address, text, sizeof(text));
    GuestSetRet(vm, r ? GuestWriteCString(vm, [NSString stringWithUTF8String:r]) : 0);
}
HLE_BIND("_inet_ntoa", hle_inet_ntoa)

HLE_DEFINE(hle_getnameinfo) {
    std::vector<uint8_t> address;
    uint32_t addressLength = GuestArg(vm, 1);
    if (!NetAddress(vm, GuestArg(vm, 0), addressLength, address)) {
        HLESetGuestErrno(vm, errno); GuestSetRet(vm, (uint32_t)EAI_SYSTEM); return;
    }
    gva_t hostOut = GuestArg(vm, 2), serviceOut = GuestArg(vm, 4);
    uint32_t hostLength = GuestArg(vm, 3), serviceLength = GuestArg(vm, 5);
    int flags = (int)GuestArg(vm, 6);
    std::vector<char> host(std::max(hostLength, 1u), 0), service(std::max(serviceLength, 1u), 0);
    int r = getnameinfo((const struct sockaddr *)address.data(), addressLength,
                        hostOut ? host.data() : nullptr, hostLength,
                        serviceOut ? service.data() : nullptr, serviceLength, flags);
    int saved = errno;
    if (r == 0) {
        if (hostOut && hostLength) GuestWrite(vm, hostOut, host.data(), strlen(host.data()) + 1);
        if (serviceOut && serviceLength) GuestWrite(vm, serviceOut, service.data(), strlen(service.data()) + 1);
    } else if (r == EAI_SYSTEM) HLESetGuestErrno(vm, saved);
    GuestSetRet(vm, (uint32_t)r);
}
HLE_BIND("_getnameinfo", hle_getnameinfo)

static gva_t NetCopyHostent(GuestVM *vm, const struct hostent *host) {
    if (!host) return 0;
    std::vector<uint32_t> aliases, addresses;
    for (char **a = host->h_aliases; a && *a; a++)
        aliases.push_back(GuestWriteCString(vm, [NSString stringWithUTF8String:*a]));
    for (char **a = host->h_addr_list; a && *a; a++) {
        gva_t copy = GuestAlloc(vm, host->h_length);
        GuestWrite(vm, copy, *a, host->h_length); addresses.push_back(copy);
    }
    aliases.push_back(0); addresses.push_back(0);
    gva_t aliasList = GuestAlloc(vm, aliases.size() * 4);
    gva_t addressList = GuestAlloc(vm, addresses.size() * 4);
    GuestWrite(vm, aliasList, aliases.data(), aliases.size() * 4);
    GuestWrite(vm, addressList, addresses.data(), addresses.size() * 4);
    uint32_t fields[5] = {GuestWriteCString(vm, [NSString stringWithUTF8String:host->h_name ?: ""]),
                          aliasList, (uint32_t)host->h_addrtype, (uint32_t)host->h_length, addressList};
    gva_t result = GuestAlloc(vm, sizeof(fields));
    GuestWrite(vm, result, fields, sizeof(fields));
    return result;
}
HLE_DEFINE(hle_gethostbyname) {
    NSString *name = GuestReadCString(vm, GuestArg(vm, 0), 1024);
    struct hostent *host = name ? gethostbyname(name.UTF8String) : nullptr;
    int saved = errno;
    gva_t result = NetCopyHostent(vm, host);
    if (!host) HLESetGuestErrno(vm, saved);
    GuestSetRet(vm, result);
}
HLE_BIND("_gethostbyname", hle_gethostbyname)
HLE_DEFINE(hle_gethostbyaddr) {
    uint32_t length = GuestArg(vm, 1);
    int family = (int)GuestArg(vm, 2);
    std::vector<uint8_t> address;
    if (!NetAddress(vm, GuestArg(vm, 0), length, address)) {
        HLESetGuestErrno(vm, errno); GuestSetRet(vm, 0); return;
    }
    struct hostent *host = gethostbyaddr(address.data(), length, family);
    int saved = errno;
    gva_t result = NetCopyHostent(vm, host);
    if (!host) HLESetGuestErrno(vm, saved);
    GuestSetRet(vm, result);
}
HLE_BIND("_gethostbyaddr", hle_gethostbyaddr)

static gva_t NetCopyAddress(GuestVM *vm, const struct sockaddr *address) {
    if (!address || !address->sa_len) return 0;
    gva_t result = GuestAlloc(vm, address->sa_len);
    GuestWrite(vm, result, address, address->sa_len);
    return result;
}
static gva_t NetCopyInterfaceData(GuestVM *vm, const struct ifaddrs *entry) {
    if (!entry->ifa_data || !entry->ifa_addr || entry->ifa_addr->sa_family != AF_LINK) return 0;
    // Darwin packs if_data to four bytes and explicitly uses timeval32 even
    // on arm64, so the statistics payload has the same layout in the guest.
    gva_t result = GuestAlloc(vm, sizeof(struct if_data));
    GuestWrite(vm, result, entry->ifa_data, sizeof(struct if_data));
    return result;
}
HLE_DEFINE(hle_getifaddrs) {
    gva_t out = GuestArg(vm, 0);
    if (!out) { NetResult(vm, -1, EFAULT); return; }
    struct ifaddrs *head = nullptr;
    int r = getifaddrs(&head), saved = errno;
    gva_t first = 0, previous = 0;
    if (r == 0) {
        for (struct ifaddrs *entry = head; entry; entry = entry->ifa_next) {
            uint32_t fields[7] = {0,
                GuestWriteCString(vm, [NSString stringWithUTF8String:entry->ifa_name ?: ""]),
                entry->ifa_flags, NetCopyAddress(vm, entry->ifa_addr),
                NetCopyAddress(vm, entry->ifa_netmask), NetCopyAddress(vm, entry->ifa_dstaddr),
                NetCopyInterfaceData(vm, entry)};
            gva_t copy = GuestAlloc(vm, sizeof(fields));
            GuestWrite(vm, copy, fields, sizeof(fields));
            if (previous) GuestWriteU32(vm, previous, copy); else first = copy;
            previous = copy;
        }
        GuestWriteU32(vm, out, first);
    }
    if (head) freeifaddrs(head);
    NetResult(vm, r, saved);
}
HLE_BIND("_getifaddrs", hle_getifaddrs)
HLE_DEFINE(hle_freeifaddrs) {
    // The host list was released after copying. GuestAlloc owns the guest
    // copies for the VM lifetime; never pass a guest pointer to freeifaddrs.
}
HLE_BIND("_freeifaddrs", hle_freeifaddrs)
