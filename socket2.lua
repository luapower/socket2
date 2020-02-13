
--Portable socket API with IOCP, epoll and kqueue for LuaJIT.
--Written by Cosmin Apreutesei. Public Domain.

if not ... then require'socket2_test'; return end

local ffi = require'ffi'
local bit = require'bit'

local glue = require'glue'
local coro = require'coro'

local push = table.insert
local pop = table.remove

local Windows = ffi.os == 'Windows'
local Linux   = ffi.os == 'Linux'
local OSX     = ffi.os == 'OSX'

assert(Windows or Linux or OSX, 'unsupported platform')

local C = Windows and ffi.load'ws2_32' or ffi.C
local M = {C = C}

local socket = {} --common socket methods
local tcp = {} --methods of tcp sockets
local udp = {} --methods of udp sockets

local check --fw. decl.
local wait --fw. decl.

local function str(s, len)
	if s == nil then return nil end
	return ffi.string(s, len)
end

--all/sockaddr construction --------------------------------------------------

ffi.cdef[[
struct sockaddr_in {
	short          family_num;
	unsigned short port;
	union {
		unsigned long uint;
		uint8_t bytes[4];
	} ip;
	char           _zero[8];
};

struct sockaddr_in6 {
	short           family_num;
	unsigned short  port;
	unsigned long   flowinfo;
	union {
		unsigned char bytes[16];
	} ip;
	unsigned long   scope_id;
};

typedef struct sockaddr {
	union {
		struct {
			short            family_num;
			unsigned short   port;
		};
		struct sockaddr_in  addr4;
		struct sockaddr_in6 addr6;
	};
} sockaddr;
]]

-- working around ABI blindness of C programmers...
if Windows then
	ffi.cdef[[
	struct addrinfo {
		int              flags;
		int              family_num;
		int              socktype_num;
		int              protocol_num;
		size_t           addrlen;
		char            *name_ptr;
		struct sockaddr *addr;
		struct addrinfo *next_ptr;
	};
	]]
else
	ffi.cdef[[
	struct addrinfo {
		int              flags;
		int              family_num;
		int              socktype_num;
		int              protocol_num;
		size_t           addrlen;
		struct sockaddr *addr;
		char            *name_ptr;
		struct addrinfo *next_ptr;
	};
	]]
end

ffi.cdef[[
int getaddrinfo(const char *node, const char *service,
	const struct addrinfo *hints, struct addrinfo **res);
void freeaddrinfo(struct addrinfo *);
]]

local socketargs
do
	local families = {
		inet  = Windows and  2 or Linux and  2,
		inet6 = Windows and 23 or Linux and 10,
		unix  = Linux and 1,
	}
	local family_map = glue.index(families)

	local socket_types = {
		tcp = Windows and 1 or Linux and 1,
		udp = Windows and 2 or Linux and 2,
		raw = Windows and 3 or Linux and 3,
	}
	local socket_type_map = glue.index(socket_types)

	local protocols = {
		ip     = Windows and   0 or Linux and   0,
		icmp   = Windows and   1 or Linux and   1,
		igmp   = Windows and   2 or Linux and   2,
		tcp    = Windows and   6 or Linux and   6,
		udp    = Windows and  17 or Linux and  17,
		raw    = Windows and 255 or Linux and 255,
		ipv6   = Windows and  41 or Linux and  41,
		icmpv6 = Windows and  58 or Linux and  58,
	}
	local protocol_map = glue.index(protocols)

	local flag_bits = {
		passive     = Windows and 0x00000001 or 0x0001,
		cannonname  = Windows and 0x00000002 or 0x0002,
		numerichost = Windows and 0x00000004 or 0x0004,
		numericserv = Windows and 0x00000008 or 0x0400,
		all         = Windows and 0x00000100 or 0x0010,
		v4mapped    = Windows and 0x00000800 or 0x0008,
		addrconfig  = Windows and 0x00000400 or 0x0020,
	}

	function socketargs(socket_type, family, protocol)
		local st = socket_types[socket_type] or socket_type or 0
		local af = families[family] or family or 0
		local prot = protocols[protocol] or protocol or 0
		return st, af, prot
	end

	local hints = ffi.new'struct addrinfo'
	local addrs = ffi.new'struct addrinfo*[1]'
	local addrinfo_ct = ffi.typeof'struct addrinfo'

	local getaddrinfo_error
	if Windows then
		function getaddrinfo_error()
			return check()
		end
	else
		ffi.cdef'const char *gai_strerror(int ecode);'
		function getaddrinfo_error(err)
			return nil, str(C.gai_strerror(err)), err
		end
	end

	function M.addr(host, port, socket_type, family, protocol, flags)
		if ffi.istype(addrinfo_ct, host) then
			return host, true --pass-through and return "not owned" flag
		elseif type(host) == 'table' then
			local t = host
			host, port, family, socket_type, protocol, flags =
				t.host, t.port, t.family, t.socket_type, t.protocol, t.flags
		end
		ffi.fill(hints, ffi.sizeof(hints))
		hints.socktype_num, hints.family_num, hints.protocol_num
			= socketargs(socket_type, family, protocol)
		hints.flags = glue.bor(flags or 0, flag_bits, true)
		local ret = C.getaddrinfo(host, port and tostring(port), hints, addrs)
		if ret ~= 0 then return getaddrinfo_error(ret) end
		return ffi.gc(addrs[0], C.freeaddrinfo)
	end

	local ai = {}
	local ai_get = {}

	function ai:free()
		ffi.gc(self, nil)
		C.freeaddrinfo(self)
	end

	function ai:next(ai)
		local ai = ai and ai.next_ptr or self
		return ai ~= nil and ai or nil
	end

	function ai:addresses()
		return ai.next, self
	end

	function ai_get:socket_type()
		return socket_type_map[self.socktype_num]
	end

	function ai_get:family()
		return family_map[self.family_num]
	end

	function ai_get:protocol()
		return protocol_map[self.protocol_num]
	end

	function ai_get:name()
		return str(self.name_ptr)
	end

	local sa = {}
	local sa_get = {}

	function sa_get:family()
		return family_map[self.family_num]
	end

	local AF_INET  = families.inet
	local AF_INET6 = families.inet6
	local AF_UNIX  = families.unix

	function sa_get:address()
		local af = self.family_num
		return af == AF_INET and self.addr4
			 or af == AF_INET6 and self.addr6
			 or error'NYI'
	end

	function sa:tostring()
		return self.address:tostring()
	end

	ffi.metatype('struct sockaddr', glue.gettersandsetters(sa_get, nil, sa))

	local sa_in4 = {}
	local sa_in4_get = {}

	function sa_in4_get:family()
		return family_map[self.family_num]
	end

	function sa_in4:tostring()
		local b = self.ip.bytes
		return string.format('%d.%d.%d.%d', b[0], b[1], b[2], b[3])
	end

	ffi.metatype('struct sockaddr_in', glue.gettersandsetters(sa_in4_get, nil, sa_in4))

	local sa_in6 = {}
	local sa_in6_get = {}

	function sa_in6_get:family()
		return family_map[self.family_num]
	end

	function sa_in6:tostring()
		local b = self.ip.bytes
		--TODO: find first longest sequence of all-zero 16bit components
		--and compress them all into a single '::'.
		return string.format('%x:%x:%x:%x:%x:%x:%x:%x',
			b[ 0]*0x100+b[ 1], b[ 2]*0x100+b[ 3], b[ 4]*0x100+b[ 5], b[ 6]*0x100+b[ 7],
			b[ 8]*0x100+b[ 9], b[10]*0x100+b[11], b[12]*0x100+b[13], b[14]*0x100+b[15])
	end

	ffi.metatype('struct sockaddr_in6', glue.gettersandsetters(sa_in6_get, nil, sa_in6))

	ffi.metatype(addrinfo_ct, glue.gettersandsetters(ai_get, nil, ai))
end

--Windows/IOCP ---------------------------------------------------------------

if Windows then

require'winapi.types'

ffi.cdef[[

typedef uintptr_t SOCKET;

// IOCP ----------------------------------------------------------------------

typedef struct _OVERLAPPED {
	ULONG_PTR Internal;
	ULONG_PTR InternalHigh;
	PVOID Pointer;
	HANDLE    hEvent;
} OVERLAPPED, *LPOVERLAPPED;

HANDLE CreateIoCompletionPort(
	HANDLE    FileHandle,
	HANDLE    ExistingCompletionPort,
	ULONG_PTR CompletionKey,
	DWORD     NumberOfConcurrentThreads
);

BOOL GetQueuedCompletionStatus(
  HANDLE       CompletionPort,
  LPDWORD      lpNumberOfBytesTransferred,
  PULONG_PTR   lpCompletionKey,
  LPOVERLAPPED *lpOverlapped,
  DWORD        dwMilliseconds
);

// Sockets -------------------------------------------------------------------

typedef HANDLE WSAEVENT;
typedef unsigned int GROUP;

typedef struct _WSAPROTOCOL_INFOW WSAPROTOCOL_INFOW, *LPWSAPROTOCOL_INFOW;

SOCKET WSASocketW(
	int                 af,
	int                 type,
	int                 protocol,
	LPWSAPROTOCOL_INFOW lpProtocolInfo,
	GROUP               g,
	DWORD               dwFlags
);
int closesocket(SOCKET s);

typedef struct WSAData {
	WORD wVersion;
	WORD wHighVersion;
	char szDescription[257];
	char szSystemStatus[129];
	unsigned short iMaxSockets; // to be ignored
	unsigned short iMaxUdpDg;   // to be ignored
	char *lpVendorInfo;         // to be ignored
} WSADATA, *LPWSADATA;

int WSAStartup(WORD wVersionRequested, LPWSADATA lpWSAData);
int WSACleanup(void);
int WSAGetLastError();

typedef struct _WSABUF {
	ULONG len;
	CHAR  *buf;
} WSABUF, *LPWSABUF;

int WSAIoctl(
	SOCKET        s,
	DWORD         dwIoControlCode,
	LPVOID        lpvInBuffer,
	DWORD         cbInBuffer,
	LPVOID        lpvOutBuffer,
	DWORD         cbOutBuffer,
	LPDWORD       lpcbBytesReturned,
	LPOVERLAPPED  lpOverlapped,
	void*         lpCompletionRoutine
);

typedef BOOL (*LPFN_CONNECTEX) (
	SOCKET s,
	const sockaddr* name,
	int namelen,
	PVOID lpSendBuffer,
	DWORD dwSendDataLength,
	LPDWORD lpdwBytesSent,
	LPOVERLAPPED lpOverlapped
);

typedef BOOL (*LPFN_ACCEPTEX) (
	SOCKET sListenSocket,
	SOCKET sAcceptSocket,
	PVOID lpOutputBuffer,
	DWORD dwReceiveDataLength,
	DWORD dwLocalAddressLength,
	DWORD dwRemoteAddressLength,
	LPDWORD lpdwBytesReceived,
	LPOVERLAPPED lpOverlapped
);

int WSASend(
	SOCKET       s,
	LPWSABUF     lpBuffers,
	DWORD        dwBufferCount,
	LPDWORD      lpNumberOfBytesSent,
	DWORD        dwFlags,
	LPOVERLAPPED lpOverlapped,
	void*        lpCompletionRoutine
);

int WSARecv(
	SOCKET       s,
	LPWSABUF     lpBuffers,
	DWORD        dwBufferCount,
	LPDWORD      lpNumberOfBytesRecvd,
	LPDWORD      lpFlags,
	LPOVERLAPPED lpOverlapped,
	void*        lpCompletionRoutine
);

int WSASendTo(
	SOCKET          s,
	LPWSABUF        lpBuffers,
	DWORD           dwBufferCount,
	LPDWORD         lpNumberOfBytesSent,
	DWORD           dwFlags,
	const sockaddr  *lpTo,
	int             iTolen,
	LPOVERLAPPED    lpOverlapped,
	void*           lpCompletionRoutine
);

int WSARecvFrom(
	SOCKET       s,
	LPWSABUF     lpBuffers,
	DWORD        dwBufferCount,
	LPDWORD      lpNumberOfBytesRecvd,
	LPDWORD      lpFlags,
	sockaddr*    lpFrom,
	LPINT        lpFromlen,
	LPOVERLAPPED lpOverlapped,
	void*        lpCompletionRoutine
);

void GetAcceptExSockaddrs(
	PVOID      lpOutputBuffer,
	DWORD      dwReceiveDataLength,
	DWORD      dwLocalAddressLength,
	DWORD      dwRemoteAddressLength,
	sockaddr** LocalSockaddr,
	LPINT      LocalSockaddrLength,
	sockaddr** RemoteSockaddr,
	LPINT      RemoteSockaddrLength
);
]]

local nbuf = ffi.new'DWORD[1]' --global buffer shared between many calls.

--error handling
do
	ffi.cdef[[
	DWORD FormatMessageA(
		DWORD dwFlags,
		LPCVOID lpSource,
		DWORD dwMessageId,
		DWORD dwLanguageId,
		LPSTR lpBuffer,
		DWORD nSize,
		va_list *Arguments
	);
	]]

	local FORMAT_MESSAGE_FROM_SYSTEM = 0x00001000

	local errbuf = glue.buffer'char[?]'

	local error_classes = {
		[10013] = 'access_denied',
	}

	function check(ret, err)
		if ret then return ret end
		local err = err or C.WSAGetLastError()
		local msg = error_classes[err]
		if not msg then
			local buf, bufsz = errbuf(256)
			local sz = ffi.C.FormatMessageA(
				FORMAT_MESSAGE_FROM_SYSTEM, nil, err, 0, buf, bufsz, nil)
			msg = sz > 0 and ffi.string(buf, sz):gsub('[\r\n]+$', '') or 'Error '..err
		end
		return nil, msg, err
	end
end

--init winsock library.
do
	local WSADATA = ffi.new'WSADATA'
	assert(check(C.WSAStartup(0x101, WSADATA) == 0))
	assert(WSADATA.wVersion == 0x101)
end

--dynamic binding of winsock functions.
local bind_winsock_func
do
	local IOC_OUT = 0x40000000
	local IOC_IN  = 0x80000000
	local IOC_WS2 = 0x08000000
	local SIO_GET_EXTENSION_FUNCTION_POINTER = bit.bor(IOC_IN, IOC_OUT, IOC_WS2, 6)

	function bind_winsock_func(socket, func_ct, func_guid)
		local cbuf = ffi.new(ffi.typeof('$[1]', ffi.typeof(func_ct)))
		assert(check(C.WSAIoctl(
			socket, SIO_GET_EXTENSION_FUNCTION_POINTER,
			func_guid, ffi.sizeof(func_guid),
			cbuf, ffi.sizeof(cbuf),
			nbuf, nil, nil
		)) == 0)
		assert(cbuf[0] ~= nil)
		return cbuf[0]
	end
end

--Binding ConnectEx() because WSAConnect() doesn't do IOCP.
local function ConnectEx(s, ...)
	ConnectEx = bind_winsock_func(s, 'LPFN_CONNECTEX', ffi.new('GUID',
		0x25a207b9,0xddf3,0x4660,{0x8e,0xe9,0x76,0xe5,0x8c,0x74,0x06,0x3e}))
	return ConnectEx(s, ...)
end

local function AcceptEx(s, ...)
	AcceptEx = bind_winsock_func(s, 'LPFN_ACCEPTEX', ffi.new('GUID',
		{0xb5367df1,0xcbac,0x11cf,{0x95,0xca,0x00,0x80,0x5f,0x48,0xa1,0x92}}))
	return AcceptEx(s, ...)
end

do
	local iocp
	function M.iocp(shared_iocp)
		if shared_iocp then
			iocp = shared_iocp
		elseif not iocp then
			local INVALID_HANDLE_VALUE = ffi.cast('HANDLE', -1)
			iocp = ffi.C.CreateIoCompletionPort(INVALID_HANDLE_VALUE, nil, 0, 0)
			assert(check(M.iocp ~= nil))
		end
		return iocp
	end
end

do
	local WSA_FLAG_OVERLAPPED = 0x01
	local INVALID_SOCKET = ffi.cast('SOCKET', -1)

	local function new(class, socktype, family, protocol)

		family = family or 'inet'
		local st, af, prot = socketargs(socktype, family, protocol)
		assert(st ~= 0, 'socket type required')
		local flags = WSA_FLAG_OVERLAPPED

		local s = C.WSASocketW(af, st, prot, nil, 0, flags)

		if s == INVALID_SOCKET then
			return check()
		end

		local iocp = M.iocp()
		if ffi.C.CreateIoCompletionPort(ffi.cast('HANDLE', s), iocp, 0, 0) ~= iocp then
			return check()
		end

		local s = {s = s, __index = class,
			type = socktype, family = family, protocol = protocol,
			_st = st, _af = af, _prot = prot,
		}
		return setmetatable(s, s)
	end
	function M.tcp(...) return new(tcp, 'tcp', ...) end
	function M.udp(...) return new(udp, 'udp', ...) end
end

function socket:close()
	C.closesocket(self.s)
end

local overlapped
do
	local jobs = {} --{job1, ...}
	local freed = {} --{job_index1, ...}

	local overlapped_ct = ffi.typeof[[
		struct {
			OVERLAPPED overlapped;
			int job_index;
		}
	]]
	local overlapped_ptr_ct = ffi.typeof('$*', overlapped_ct)

	local OVERLAPPED = ffi.typeof'OVERLAPPED'
	local LPOVERLAPPED = ffi.typeof'LPOVERLAPPED'

	function overlapped(done)
		if #freed > 0 then
			local job_index = pop(freed)
			local job = jobs[job_index]
			job.done = done
			local o = ffi.cast(LPOVERLAPPED, job._overlapped)
			ffi.fill(o, ffi.sizeof(OVERLAPPED))
			return o, job
		else
			local job = {done = done}
			local o = overlapped_ct()
			job._overlapped = o
			push(jobs, job)
			o.job_index = #jobs
			return ffi.cast(LPOVERLAPPED, o), job
		end
	end

	function free_overlapped(o)
		local o = ffi.cast(overlapped_ptr_ct, o)
		push(freed, o.job_index)
		return jobs[o.job_index]
	end

	local keybuf = ffi.new'ULONG_PTR[1]'
	local obuf = ffi.new'LPOVERLAPPED[1]'

	local WAIT_TIMEOUT = 258

	function M.poll(timeout)
		timeout = glue.clamp((timeout or 1/0) * 1000, 0, 0xffffffff)
		local ok = ffi.C.GetQueuedCompletionStatus(
			M.iocp(), nbuf, keybuf, obuf, timeout) ~= 0
		if not ok then
			local err = C.WSAGetLastError()
			if err == WAIT_TIMEOUT then
				return false, 'timeout'
			end
			return check(nil, err)
		end
		local o = obuf[0]
		local n = nbuf[0]
		local job = free_overlapped(o)
		coro.transfer(job.thread, job:done(n))
		return true
	end
end

do
	local WSA_IO_PENDING = 997

	local function check_pending(ok, job)
		if ok or C.WSAGetLastError() == WSA_IO_PENDING then
			job.thread = coro.running()
			return wait()
		end
		return check()
	end

	local function return_true()
		return true
	end

	function tcp:connect(...)
		if not self._bound then
			--ConnectEx requires binding first.
			local ok, err, errcode = self:bind(nil, 0, self._st, self._af, self._prot)
			if not ok then return nil, err, errcode end
		end
		local ai, err, errcode = M.addr(...)
		if not ai then return false, err, errcode end
		local o, job = overlapped(return_true)
		local ok = ConnectEx(self.s, ai.addr, ai.addrlen, nil, 0, nil, o) == 1
		if not err then ai:free() end
		return check_pending(ok, job)
	end

	local accept_buf_ct = ffi.typeof[[
		struct {
			struct sockaddr local_addr;
			char reserved[16];
			struct sockaddr remote_addr;
			char reserved[16];
		}
	]]
	local accept_buf = accept_buf_ct()
	local sa_len = ffi.sizeof(accept_buf) / 2
	function tcp:accept()
		local client_s, err, errcode = M.tcp(self._af, self._prot)
		if not client_s then return nil, err, errcode end
		local o, job = overlapped(return_true)
		local ok = AcceptEx(self.s, client_s.s, accept_buf, 0, sa_len, sa_len, nbuf, o) == 1
		local ok, err, errcode = check_pending(ok, job)
		if not ok then return nil, err, errcode end
		return client_s, accept_buf.remote_addr, accept_buf.local_addr
	end

	local wsabuf = ffi.new'WSABUF'

	local pchar_t = ffi.typeof'char*'
	local flagsbuf = ffi.new'DWORD[1]'

	local function io_done(job, n)
		job.socket = nil
		return n
	end

	function tcp:send(buf, len)
		wsabuf.buf = type(buf) == 'string' and ffi.cast(pchar_t, buf) or buf
		wsabuf.len = len or #buf
		local o, job = overlapped(io_done)
		local ok = C.WSASend(self.s, wsabuf, 1, nbuf, 0, o, nil) == 0
		return check_pending(ok, job)
	end

	function udp:send(buf, len, ...)
		local ai, err, errcode = M.addr(...)
		if not ai then return nil, err, errcode end
		wsabuf.buf = type(buf) == 'string' and ffi.cast(pchar_t, buf) or buf
		wsabuf.len = len or #buf
		local o, job = overlapped(io_done)
		local ok = C.WSASendTo(self.s, wsabuf, 1, nbuf, 0, ai.addr, ai.addrlen, o, nil) == 0
		ai:free()
		return check_pending(ok, job)
	end

	function tcp:recv(buf, len)
		wsabuf.buf = buf
		wsabuf.len = len
		local o, job = overlapped(io_done)
		flagsbuf[0] = 0
		local ok = C.WSARecv(self.s, wsabuf, 1, nbuf, flagsbuf, o, nil) == 0
		return check_pending(ok, job)
	end

	function udp:recv(buf, len, ...)
		local ai, err, errcode = M.addr(...)
		if not ai then return nil, err, errcode end
		wsabuf.buf = buf
		wsabuf.len = len
		local o, job = overlapped(io_done)
		flagsbuf[0] = 0
		local ok = C.WSARecvFrom(self.s, wsabuf, 1, nbuf, flagsbuf, ai.addr, ai.addrlen, o, nil) == 0
		ai:free()
		return check_pending(ok, job)
	end
end

end --if Windows

--POSIX/berkley sockets ------------------------------------------------------

local register_socket, unregister_socket --fw. decl.

if Linux or OSX then

ffi.cdef[[
typedef int SOCKET;
int socket(int af, int type, int protocol);
int accept(int s, struct sockaddr *addr, int *addrlen);
int accept4(int s, struct sockaddr *addr, int *addrlen, int flags);
int close(int s);
int connect(int s, const struct sockaddr *name, int namelen);
int ioctl(int s, long cmd, unsigned long *argp, ...);
int recv(int s, char *buf, int len, int flags);
int recvfrom(int s, char *buf, int len, int flags, struct sockaddr *from, int *fromlen);
int send(int s, const char *buf, int len, int flags);
int sendto(int s, const char *buf, int len, int flags, const struct sockaddr *to, int tolen);
int shutdown(int s, int how);
]]

--error handling.
ffi.cdef'char *strerror(int errnum);'
function check(ret)
	if ret then return ret end
	local err = ffi.errno()
	return ret, str(C.strerror(err)), err
end

local SOCK_NONBLOCK = Linux and tonumber(4000, 8)

local function wrap(s, class, socktype, family, protocol, st, af, prot)
	if s == -1 then
		return check()
	end
	local s = {s = s, __index = class,
		type = socktype, family = family, protocol = protocol,
		_st = st, _af = af, _prot = prot,
	}
	register_socket(s)
	return setmetatable(s, s)
end

do
	local function new(class, socktype, family, protocol)
		family = family or 'inet'
		local st, af, prot = socketargs(socktype, family, protocol)
		assert(st ~= 0, 'socket type required')
		return wrap(C.socket(af, bit.bor(st, SOCK_NONBLOCK), prot),
			class, socktype, family, protocol, st, af, prot)
	end
	function M.tcp(...) return new(tcp, 'tcp', ...) end
	function M.udp(...) return new(udp, 'udp', ...) end
end

function socket:close()
	unregister_socket(self)
	local ok = C.close(self.s) == 0
	return check(ok)
end

local EWOULDBLOCK = 11 --alias of EAGAIN in Linux
local EINPROGRESS = 115

local function make_async(thread_field, f, wait_errno)
	return function(self, ...)
		::again::
		local ret = f(self, ...)
		if ret >= 0 then return ret end
		if ffi.errno() == wait_errno then
			self[thread_field] = coro.running()
			wait()
			goto again
		end
		return check()
	end
end

do
	local connect = make_async('_wt', function(self, ai)
		return C.connect(self.s, ai.addr, ai.addrlen)
	end, EINPROGRESS)

	function socket:connect(...)
		local ai, err = M.addr(...)
		if not ai then
			return false, err
		end
		return connect(self, ai)
	end
end

do
	local nbuf = ffi.new'int[1]'
	local accept_buf = ffi.new'sockaddr'
	local accept_buf_size = ffi.sizeof(accept_buf)

	local tcp_accept = make_async('_rt', function(self)
		nbuf[0] = accept_buf_size
		return C.accept4(self.s, accept_buf, nbuf, SOCK_NONBLOCK)
	end, EWOULDBLOCK)

	function tcp:accept()
		local s, err, errno = tcp_accept(self)
		if not s then return nil, err, errno end
		return wrap(s, tcp, self.type, self.family, self.protocol,
			self._st, self._af, self._prot), accept_buf
	end
end

tcp.send = make_async('_wt', function(self, buf, len, flags)
	return C.send(self.s, buf, len or #buf, flags or 0)
end, EWOULDBLOCK)

tcp.recv = make_async('_rt', function(self, buf, len, flags)
	return C.recv(self.s, buf, len, flags or 0)
end, EWOULDBLOCK)

do
	local udp_send = make_async('_wt', function(self, buf, len, flags, ai)
		return C.sendto(self.s, buf, len or #buf, flags or 0, ai.addr, ai.addrlen)
	end, EWOULDBLOCK)

	function udp:send(buf, len, flags, ...)
		local ai, err, errcode = M.addr(...)
		if not ai then return nil, err, errcode end
		return udp_send(self, buf, len, flags, ai)
	end
end

do
	local udp_recv = make_async('_rt', function(self, buf, len, flags, ai)
		local ret = C.recvfrom(self.s, buf, len, flags or 0, ai.addr, ai.addrlen)
	end, EWOULDBLOCK)

	function udp:recv(buf, len, flags, ...)
		local ai, err, errcode = M.addr(...)
		if not ai then return nil, err, errcode end
		return udp_recv(self, buf, len, flags, ai)
	end
end

end --if not Windows

--Linux/epoll ----------------------------------------------------------------

if Linux then

ffi.cdef[[
typedef union epoll_data {
	void *ptr;
	int fd;
	uint32_t u32;
	uint64_t u64;
} epoll_data_t;

struct epoll_event {
	uint32_t events;
	epoll_data_t data;
};

int epoll_create1(int flags);
int epoll_ctl(int epfd, int op, int fd, struct epoll_event *event);
int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout);
]]

local EPOLLIN        = 0x0001
local EPOLLOUT       = 0x0004
local EPOLLET        = 2^31

local EPOLL_CTL_ADD = 1
local EPOLL_CTL_DEL = 2
local EPOLL_CTL_MOD = 3

do
	local epoll_fd
	function M.epoll_fd(shared_epoll_fd, flags)
		if shared_epoll_fd then
			epoll_fd = shared_epoll_fd
		elseif not epoll_fd then
			flags = flags or 0 --TODO: flags
			epoll_fd = C.epoll_create1(flags)
			assert(check(epoll_fd >= 0))
		end
		return epoll_fd
	end
end

do
	local sockets = {}
	local free_indices = {}
	local n = 0

	--[[local]] function register_socket(s)
		local i = pop(free_indices)
		if not i then
			n = n + 1
			i = n
		end
		s._i = i
		s._e = e
		sockets[i] = s
		local e = ffi.new'struct epoll_event'
		e.data.u32 = i
		e.events = EPOLLIN + EPOLLOUT + EPOLLET
		assert(check(C.epoll_ctl(M.epoll_fd(), EPOLL_CTL_ADD, s.s, e) == 0))
	end

	--[[local]] function unregister_socket(s)
		assert(check(C.epoll_ctl(M.epoll_fd(), EPOLL_CTL_DEL, s.s, s._e) == 0))
		local i = s._i
		sockets[i] = false
		push(free_indices, i)
	end

	local function resume(socket, e, event, thread_field)
		if bit.band(e, event) ~= 0 then --read
			local thread = socket[thread_field]
			if not thread then return end --misfire.
			socket[thread_field] = false
			coro.transfer(thread)
		end
	end
	local maxevents = 1
	local events = ffi.new('struct epoll_event[?]', maxevents)
	function M.poll(timeout)
		timeout = math.max((timeout or 1/0) * 1000, 0)
		if timeout > 0x7fffffff then timeout = -1 end --infinite
		local n = C.epoll_wait(M.epoll_fd(), events, maxevents, timeout)
		if n > 0 then
			for i = 0, n-1 do
				local socket = sockets[events[i].data.u32]
				local e = events[i].events
				resume(socket, e, EPOLLIN , '_rt')
				resume(socket, e, EPOLLOUT, '_wt')
			end
			return true
		elseif n == 0 then
			return false, 'timeout'
		else
			return check()
		end
	end
end

end --if Linux

--OSX/kqueue -----------------------------------------------------------------

if OSX then

ffi.cdef[[
int kqueue(void);
int kevent(int kq, const struct kevent *changelist, int nchanges,
	struct kevent *eventlist, int nevents,
	const struct timespec *timeout);
// EV_SET(&kev, ident, filter, flags, fflags, data, udata);
]]

end --if OSX

--all/binding ----------------------------------------------------------------

ffi.cdef[[
int bind(SOCKET s, const sockaddr*, int namelen);
]]

function socket:bind(...)
	local ai, err, errcode = M.addr(...)
	if not ai then return false, err, errcode end
	local ok = C.bind(self.s, ai.addr, ai.addrlen) == 0
	if not err then ai:free() end
	if not ok then return check() end
	self._bound = true
	return true
end

--all/listen -----------------------------------------------------------------

ffi.cdef[[
int listen(SOCKET s, int backlog);
]]

function tcp:listen(backlog)
	return check(C.listen(self.s, backlog or 0x7fffffff) == 0)
end

--inherit socket -------------------------------------------------------------

glue.update(tcp, socket)
glue.update(udp, socket)

--coroutine-based scheduler --------------------------------------------------

local loop_thread

--[[local]] function wait()
	assert(coro.running() ~= loop_thread, 'trying to I/O from the main thread')
	return coro.transfer(loop_thread)
end

--create a thread set up to transfer control to the loop thread on finish,
--and run it. return it while suspended in the first async socket call.
--poll() will resume it back afterwards by calling the job's done() method.
function M.newthread(handler, ...)
	--wrap handler so that it terminates in current loop_thread.
	local thread = coro.create(function(...)
		local ok, err = glue.pcall(handler, ...) --last chance to get stacktrace.
		if not ok then error(err, 2) end
		coro.transfer(loop_thread)
	end)
	local real_loop_thread = loop_thread
	local loop_thread = coro.running() --make it get back here.
	coro.transfer(thread, ...)
	loop_thread = real_loop_thread
	return thread
end

local stop = false
function M.stop() stop = true end
function M.start(timeout)
	loop_thread = coro.running()
	repeat
		local ret, err, errcode = M.poll(timeout)
		if not ret then return ret, err, errcode end
	until stop
	return true
end

return M
