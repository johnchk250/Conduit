#include "bluetooth_proxy_win.h"

#include <flutter/method_result.h>
#include <winsock2.h>
#include <ws2bth.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bluetoothapis.h>

#include <atomic>
#include <cstdint>
#include <iomanip>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {
const GUID kServiceUuid = {
    0x7c6b8a10,
    0x31d2,
    0x4d8e,
    {0x9f, 0x54, 0x19, 0xad, 0xf3, 0x8c, 0x6d, 0x21}};
constexpr wchar_t kServiceName[] = L"Conduit";

void CloseSocket(SOCKET socket) {
  if (socket == INVALID_SOCKET) return;
  shutdown(socket, SD_BOTH);
  closesocket(socket);
}

std::string LastSocketError(const char* operation) {
  return std::string(operation) + " failed (Windows error " +
         std::to_string(WSAGetLastError()) + ")";
}

std::string WideToUtf8(const wchar_t* value) {
  if (!value || !*value) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value, -1, nullptr, 0,
                                       nullptr, nullptr);
  if (size <= 1) return {};
  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(CP_UTF8, 0, value, -1, result.data(), size, nullptr,
                      nullptr);
  result.pop_back();
  return result;
}

std::string EndpointId(BTH_ADDR address) {
  std::ostringstream stream;
  stream << std::hex << std::setw(12) << std::setfill('0') << address;
  return stream.str();
}

bool ParseEndpoint(const std::string& endpoint, BTH_ADDR* address,
                   ULONG* channel) {
  const size_t separator = endpoint.find(':');
  try {
    *address = std::stoull(endpoint.substr(0, separator), nullptr, 16);
    *channel = separator == std::string::npos
                   ? 0
                   : std::stoul(endpoint.substr(separator + 1));
    return *address != 0;
  } catch (...) {
    return false;
  }
}

bool ConnectWithTimeout(SOCKET socket, const SOCKADDR_BTH& remote,
                        DWORD timeout_ms) {
  u_long non_blocking = 1;
  if (ioctlsocket(socket, FIONBIO, &non_blocking) == SOCKET_ERROR) return false;
  const int result =
      connect(socket, reinterpret_cast<const sockaddr*>(&remote), sizeof(remote));
  if (result == SOCKET_ERROR) {
    const int error = WSAGetLastError();
    if (error != WSAEWOULDBLOCK && error != WSAEINPROGRESS &&
        error != WSAEINVAL) {
      non_blocking = 0;
      ioctlsocket(socket, FIONBIO, &non_blocking);
      return false;
    }
    fd_set writable;
    fd_set failed;
    FD_ZERO(&writable);
    FD_ZERO(&failed);
    FD_SET(socket, &writable);
    FD_SET(socket, &failed);
    timeval timeout{};
    timeout.tv_sec = static_cast<long>(timeout_ms / 1000);
    timeout.tv_usec = static_cast<long>((timeout_ms % 1000) * 1000);
    const int selected =
        select(0, nullptr, &writable, &failed, &timeout);
    int socket_error = 0;
    int error_size = sizeof(socket_error);
    if (selected <= 0 || FD_ISSET(socket, &failed) ||
        getsockopt(socket, SOL_SOCKET, SO_ERROR,
                   reinterpret_cast<char*>(&socket_error),
                   &error_size) == SOCKET_ERROR ||
        socket_error != 0) {
      if (selected == 0) WSASetLastError(WSAETIMEDOUT);
      non_blocking = 0;
      ioctlsocket(socket, FIONBIO, &non_blocking);
      return false;
    }
  }
  non_blocking = 0;
  return ioctlsocket(socket, FIONBIO, &non_blocking) != SOCKET_ERROR;
}

struct LocalListener {
  SOCKET socket = INVALID_SOCKET;
  int port = 0;
};

LocalListener ListenLoopback() {
  LocalListener result;
  result.socket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (result.socket == INVALID_SOCKET) return result;
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = 0;
  if (bind(result.socket, reinterpret_cast<sockaddr*>(&address),
           sizeof(address)) == SOCKET_ERROR ||
      listen(result.socket, 1) == SOCKET_ERROR) {
    CloseSocket(result.socket);
    result.socket = INVALID_SOCKET;
    return result;
  }
  int length = sizeof(address);
  getsockname(result.socket, reinterpret_cast<sockaddr*>(&address), &length);
  result.port = ntohs(address.sin_port);
  return result;
}

SOCKET ConnectLoopback(int port, int* source_port) {
  SOCKET result = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (result == INVALID_SOCKET) return result;
  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  address.sin_port = htons(static_cast<u_short>(port));
  if (connect(result, reinterpret_cast<sockaddr*>(&address), sizeof(address)) ==
      SOCKET_ERROR) {
    CloseSocket(result);
    return INVALID_SOCKET;
  }
  BOOL no_delay = TRUE;
  setsockopt(result, IPPROTO_TCP, TCP_NODELAY,
             reinterpret_cast<const char*>(&no_delay), sizeof(no_delay));
  if (source_port) {
    sockaddr_in local{};
    int length = sizeof(local);
    getsockname(result, reinterpret_cast<sockaddr*>(&local), &length);
    *source_port = ntohs(local.sin_port);
  }
  return result;
}

class Bridge : public std::enable_shared_from_this<Bridge> {
 public:
  Bridge(SOCKET bluetooth, SOCKET local)
      : bluetooth_(bluetooth), local_(local) {}

  void Start() {
    auto self = shared_from_this();
    std::thread([self] { self->Copy(self->bluetooth_, self->local_); }).detach();
    std::thread([self] { self->Copy(self->local_, self->bluetooth_); }).detach();
  }

 private:
  void Copy(SOCKET from, SOCKET to) {
    std::vector<char> bytes(32 * 1024);
    while (!closed_) {
      const int received = recv(from, bytes.data(), static_cast<int>(bytes.size()), 0);
      if (received <= 0) break;
      int offset = 0;
      while (offset < received) {
        const int sent = send(to, bytes.data() + offset, received - offset, 0);
        if (sent <= 0) {
          offset = received;
          break;
        }
        offset += sent;
      }
    }
    Close();
  }

  void Close() {
    if (closed_.exchange(true)) return;
    CloseSocket(bluetooth_);
    CloseSocket(local_);
    bluetooth_ = INVALID_SOCKET;
    local_ = INVALID_SOCKET;
  }

  SOCKET bluetooth_ = INVALID_SOCKET;
  SOCKET local_ = INVALID_SOCKET;
  std::atomic<bool> closed_{false};
};
}  // namespace

class BluetoothProxyWin::Impl {
 public:
  Impl(Dispatch dispatch, Emit emit)
      : dispatch_(std::move(dispatch)), emit_(std::move(emit)) {
    WSADATA data{};
    winsock_ready_ = WSAStartup(MAKEWORD(2, 2), &data) == 0;
  }

  ~Impl() {
    Stop();
    if (winsock_ready_) WSACleanup();
  }

  flutter::EncodableMap Start(int dart_port) {
    dart_port_ = dart_port;
    if (!winsock_ready_ || dart_port_ <= 0) return Result(false, "Bluetooth host unavailable");
    if (running_) return Result(true, "Bluetooth ready - LAN remains preferred");

    const std::string error = StartServer();
    if (!error.empty()) return Result(false, "Bluetooth unavailable: " + error);

    running_ = true;
    accept_thread_ = std::thread([this] { AcceptLoop(); });
    discovery_thread_ = std::thread([this] { DiscoverLoop(); });
    return Result(true, "Bluetooth ready - LAN remains preferred");
  }

  void Stop() {
    if (!running_.exchange(false) && server_ == INVALID_SOCKET) return;
    if (service_registered_) {
      WSASetServiceW(&service_query_, RNRSERVICE_DELETE, 0);
      service_registered_ = false;
    }
    CloseSocket(server_);
    server_ = INVALID_SOCKET;
    if (accept_thread_.joinable() && accept_thread_.get_id() != std::this_thread::get_id()) {
      accept_thread_.join();
    }
    if (discovery_thread_.joinable() && discovery_thread_.get_id() != std::this_thread::get_id()) {
      discovery_thread_.join();
    }
  }

  void Connect(const std::string& endpoint_id,
               std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    const auto dispatch = dispatch_;
    std::thread([endpoint_id, result = std::move(result), dispatch] {
      BTH_ADDR address = 0;
      ULONG channel = 0;
      if (!ParseEndpoint(endpoint_id, &address, &channel)) {
        dispatch([result] { result->Error("BLUETOOTH_ENDPOINT", "Invalid Bluetooth endpoint"); });
        return;
      }
      SOCKET bluetooth = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
      if (bluetooth == INVALID_SOCKET) {
        const std::string message = LastSocketError("Bluetooth socket");
        dispatch([result, message] { result->Error("BLUETOOTH_CONNECT", message); });
        return;
      }
      SOCKADDR_BTH remote{};
      remote.addressFamily = AF_BTH;
      remote.btAddr = address;
      remote.serviceClassId = kServiceUuid;
      remote.port = channel;
      if (!ConnectWithTimeout(bluetooth, remote, 5000)) {
        const std::string message = LastSocketError("Bluetooth connect");
        CloseSocket(bluetooth);
        dispatch([result, message] { result->Error("BLUETOOTH_CONNECT", message); });
        return;
      }
      LocalListener local = ListenLoopback();
      if (local.socket == INVALID_SOCKET) {
        CloseSocket(bluetooth);
        dispatch([result] { result->Error("BLUETOOTH_CONNECT", "Could not create loopback bridge"); });
        return;
      }
      dispatch([result, port = local.port] { result->Success(flutter::EncodableValue(port)); });
      SOCKET dart = accept(local.socket, nullptr, nullptr);
      CloseSocket(local.socket);
      if (dart == INVALID_SOCKET) {
        CloseSocket(bluetooth);
        return;
      }
      std::make_shared<Bridge>(bluetooth, dart)->Start();
    }).detach();
  }

 private:
  flutter::EncodableMap Result(bool started, const std::string& status) const {
    return {{flutter::EncodableValue("started"), flutter::EncodableValue(started)},
            {flutter::EncodableValue("status"), flutter::EncodableValue(status)}};
  }

  std::string StartServer() {
    server_ = socket(AF_BTH, SOCK_STREAM, BTHPROTO_RFCOMM);
    if (server_ == INVALID_SOCKET) return LastSocketError("Bluetooth socket");

    SOCKADDR_BTH local{};
    local.addressFamily = AF_BTH;
    local.btAddr = 0;
    local.serviceClassId = kServiceUuid;
    local.port = BT_PORT_ANY;
    if (bind(server_, reinterpret_cast<sockaddr*>(&local), sizeof(local)) == SOCKET_ERROR ||
        listen(server_, 4) == SOCKET_ERROR) {
      const std::string error = LastSocketError("Bluetooth listener");
      CloseSocket(server_);
      server_ = INVALID_SOCKET;
      return error;
    }
    int local_size = sizeof(local);
    if (getsockname(server_, reinterpret_cast<sockaddr*>(&local), &local_size) == SOCKET_ERROR) {
      const std::string error = LastSocketError("Bluetooth channel lookup");
      CloseSocket(server_);
      server_ = INVALID_SOCKET;
      return error;
    }

    service_address_ = local;
    service_csaddr_ = {};
    service_csaddr_.LocalAddr.lpSockaddr = reinterpret_cast<sockaddr*>(&service_address_);
    service_csaddr_.LocalAddr.iSockaddrLength = sizeof(service_address_);
    service_csaddr_.RemoteAddr = service_csaddr_.LocalAddr;
    service_csaddr_.iSocketType = SOCK_STREAM;
    service_csaddr_.iProtocol = BTHPROTO_RFCOMM;
    service_query_ = {};
    service_query_.dwSize = sizeof(service_query_);
    service_query_.lpszServiceInstanceName = const_cast<wchar_t*>(kServiceName);
    service_query_.lpServiceClassId = const_cast<GUID*>(&kServiceUuid);
    service_query_.dwNameSpace = NS_BTH;
    service_query_.dwNumberOfCsAddrs = 1;
    service_query_.lpcsaBuffer = &service_csaddr_;
    if (WSASetServiceW(&service_query_, RNRSERVICE_REGISTER, 0) == SOCKET_ERROR) {
      const std::string error = LastSocketError("Bluetooth service advertisement");
      CloseSocket(server_);
      server_ = INVALID_SOCKET;
      return error;
    }
    service_registered_ = true;
    return {};
  }

  void AcceptLoop() {
    while (running_) {
      SOCKADDR_BTH remote{};
      int length = sizeof(remote);
      SOCKET bluetooth = accept(server_, reinterpret_cast<sockaddr*>(&remote), &length);
      if (bluetooth == INVALID_SOCKET) {
        if (running_) EmitStatus(LastSocketError("Bluetooth accept"));
        break;
      }
      ProxyIncoming(bluetooth, remote.btAddr);
    }
  }

  void ProxyIncoming(SOCKET bluetooth, BTH_ADDR address) {
    const int dart_port = dart_port_;
    std::thread([this, bluetooth, address, dart_port] {
      int source_port = 0;
      SOCKET dart = ConnectLoopback(dart_port, &source_port);
      if (dart == INVALID_SOCKET) {
        CloseSocket(bluetooth);
        return;
      }
      flutter::EncodableMap args = {
          {flutter::EncodableValue("sourcePort"), flutter::EncodableValue(source_port)},
          {flutter::EncodableValue("id"), flutter::EncodableValue(EndpointId(address))}};
      dispatch_([this, args] { emit_("incomingProxy", flutter::EncodableValue(args)); });
      Sleep(100);
      std::make_shared<Bridge>(bluetooth, dart)->Start();
    }).detach();
  }

  void DiscoverLoop() {
    while (running_) {
      DiscoverOnce();
      for (int i = 0; i < 30 && running_; ++i) Sleep(1000);
    }
  }

  void DiscoverOnce() {
    BLUETOOTH_DEVICE_SEARCH_PARAMS search{};
    search.dwSize = sizeof(search);
    search.fReturnAuthenticated = TRUE;
    search.fReturnRemembered = TRUE;
    search.fReturnUnknown = FALSE;
    search.fReturnConnected = TRUE;
    search.fIssueInquiry = FALSE;
    BLUETOOTH_DEVICE_INFO device{};
    device.dwSize = sizeof(device);
    HBLUETOOTH_DEVICE_FIND paired = BluetoothFindFirstDevice(&search, &device);
    if (paired) {
      do {
        EmitDevice(device.Address.ullLong, WideToUtf8(device.szName));
        device = {};
        device.dwSize = sizeof(device);
      } while (BluetoothFindNextDevice(paired, &device));
      BluetoothFindDeviceClose(paired);
    }

  }

  void EmitDevice(BTH_ADDR address, const std::string& name) {
    flutter::EncodableMap args = {
        {flutter::EncodableValue("id"), flutter::EncodableValue(EndpointId(address))},
        {flutter::EncodableValue("name"),
         flutter::EncodableValue(name.empty() ? "Bluetooth device" : name)}};
    dispatch_([this, args] { emit_("deviceFound", flutter::EncodableValue(args)); });
  }

  void EmitStatus(const std::string& message) {
    flutter::EncodableMap args = {
        {flutter::EncodableValue("message"), flutter::EncodableValue(message)}};
    dispatch_([this, args] { emit_("status", flutter::EncodableValue(args)); });
  }

  Dispatch dispatch_;
  Emit emit_;
  bool winsock_ready_ = false;
  std::atomic<bool> running_{false};
  int dart_port_ = 0;
  SOCKET server_ = INVALID_SOCKET;
  bool service_registered_ = false;
  SOCKADDR_BTH service_address_{};
  CSADDR_INFO service_csaddr_{};
  WSAQUERYSETW service_query_{};
  std::thread accept_thread_;
  std::thread discovery_thread_;
};

BluetoothProxyWin::BluetoothProxyWin(Dispatch dispatch, Emit emit)
    : impl_(std::make_unique<Impl>(std::move(dispatch), std::move(emit))) {}

BluetoothProxyWin::~BluetoothProxyWin() = default;

flutter::EncodableMap BluetoothProxyWin::Start(int dart_port) {
  return impl_->Start(dart_port);
}

void BluetoothProxyWin::Stop() { impl_->Stop(); }

void BluetoothProxyWin::Connect(
    const std::string& endpoint_id,
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  impl_->Connect(endpoint_id, std::move(result));
}
