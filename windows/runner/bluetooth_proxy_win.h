#ifndef RUNNER_BLUETOOTH_PROXY_WIN_H_
#define RUNNER_BLUETOOTH_PROXY_WIN_H_

#include <flutter/encodable_value.h>

#include <functional>
#include <memory>
#include <string>

namespace flutter {
template <typename T>
class MethodResult;
}

class BluetoothProxyWin {
 public:
  using Dispatch = std::function<void(std::function<void()>)>;
  using Emit = std::function<void(const std::string&, const flutter::EncodableValue&)>;

  BluetoothProxyWin(Dispatch dispatch, Emit emit);
  ~BluetoothProxyWin();

  flutter::EncodableMap Start(int dart_port);
  void Stop();
  void Connect(
      const std::string& endpoint_id,
      std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  class Impl;
  std::unique_ptr<Impl> impl_;
};

#endif  // RUNNER_BLUETOOTH_PROXY_WIN_H_
