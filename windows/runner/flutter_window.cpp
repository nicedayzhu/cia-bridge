#include "flutter_window.h"

#include <iphlpapi.h>
#include <filesystem>
#include <shobjidl.h>
#include <wrl/client.h>

#include <cstdio>
#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

flutter::EncodableList PickShareFiles(HWND owner, HRESULT* status) {
  using Microsoft::WRL::ComPtr;
  flutter::EncodableList selected_files;

  ComPtr<IFileOpenDialog> dialog;
  *status = CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                             CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
  if (FAILED(*status)) {
    return selected_files;
  }

  DWORD options = 0;
  *status = dialog->GetOptions(&options);
  if (FAILED(*status)) {
    return selected_files;
  }
  *status = dialog->SetOptions(options | FOS_ALLOWMULTISELECT |
                               FOS_FILEMUSTEXIST | FOS_FORCEFILESYSTEM);
  if (FAILED(*status)) {
    return selected_files;
  }

  const COMDLG_FILTERSPEC filters[] = {
      {L"Nintendo 3DS files", L"*.cia;*.tik;*.cetk;*.3dsx;*.zip"},
      {L"All files", L"*.*"},
  };
  dialog->SetFileTypes(2, filters);
  dialog->SetFileTypeIndex(1);
  dialog->SetTitle(L"Select installation files or a LayeredFS patch ZIP");

  *status = dialog->Show(owner);
  if (*status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    *status = S_OK;
    return selected_files;
  }
  if (FAILED(*status)) {
    return selected_files;
  }

  ComPtr<IShellItemArray> items;
  *status = dialog->GetResults(&items);
  if (FAILED(*status)) {
    return selected_files;
  }

  DWORD count = 0;
  *status = items->GetCount(&count);
  if (FAILED(*status)) {
    return selected_files;
  }

  for (DWORD index = 0; index < count; ++index) {
    ComPtr<IShellItem> item;
    if (FAILED(items->GetItemAt(index, &item))) {
      continue;
    }
    PWSTR raw_path = nullptr;
    if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path)) ||
        raw_path == nullptr) {
      continue;
    }
    const std::filesystem::path path(raw_path);
    CoTaskMemFree(raw_path);

    WIN32_FILE_ATTRIBUTE_DATA attributes{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard,
                              &attributes)) {
      continue;
    }
    const int64_t size =
        (static_cast<int64_t>(attributes.nFileSizeHigh) << 32) |
        attributes.nFileSizeLow;
    flutter::EncodableMap file;
    file[flutter::EncodableValue("path")] =
        flutter::EncodableValue(Utf8FromUtf16(path.c_str()));
    file[flutter::EncodableValue("name")] = flutter::EncodableValue(
        Utf8FromUtf16(path.filename().c_str()));
    file[flutter::EncodableValue("size")] = flutter::EncodableValue(size);
    selected_files.emplace_back(file);
  }

  *status = S_OK;
  return selected_files;
}

flutter::EncodableList ListIpv4Neighbors() {
  flutter::EncodableList neighbors;
  ULONG size = 0;
  if (GetIpNetTable(nullptr, &size, FALSE) != ERROR_INSUFFICIENT_BUFFER ||
      size == 0) {
    return neighbors;
  }

  std::vector<unsigned char> buffer(size);
  auto* table = reinterpret_cast<PMIB_IPNETTABLE>(buffer.data());
  if (GetIpNetTable(table, &size, FALSE) != NO_ERROR) {
    return neighbors;
  }

  for (DWORD index = 0; index < table->dwNumEntries; ++index) {
    const MIB_IPNETROW& row = table->table[index];
    if (row.dwPhysAddrLen < 6 ||
        (row.dwType != MIB_IPNET_TYPE_DYNAMIC &&
         row.dwType != MIB_IPNET_TYPE_STATIC)) {
      continue;
    }
    const auto* address = reinterpret_cast<const unsigned char*>(&row.dwAddr);
    char ip[16]{};
    std::snprintf(ip, sizeof(ip), "%u.%u.%u.%u", address[0], address[1],
                  address[2], address[3]);
    char mac[18]{};
    std::snprintf(mac, sizeof(mac), "%02X:%02X:%02X:%02X:%02X:%02X",
                  row.bPhysAddr[0], row.bPhysAddr[1], row.bPhysAddr[2],
                  row.bPhysAddr[3], row.bPhysAddr[4], row.bPhysAddr[5]);
    flutter::EncodableMap neighbor;
    neighbor[flutter::EncodableValue("ip")] = flutter::EncodableValue(ip);
    neighbor[flutter::EncodableValue("mac")] = flutter::EncodableValue(mac);
    neighbors.emplace_back(neighbor);
  }
  return neighbors;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  native_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "cia_bridge/native",
          &flutter::StandardMethodCodec::GetInstance());
  native_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "listNeighbors") {
          result->Success(flutter::EncodableValue(ListIpv4Neighbors()));
          return;
        }
        if (call.method_name() != "pickFiles") {
          result->NotImplemented();
          return;
        }
        HRESULT status = S_OK;
        auto files = PickShareFiles(GetHandle(), &status);
        if (FAILED(status)) {
          result->Error("file_dialog_failed",
                        "Windows could not open the file picker.");
          return;
        }
        result->Success(flutter::EncodableValue(files));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
