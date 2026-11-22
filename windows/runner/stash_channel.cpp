#include "stash_channel.h"

#include <flutter/standard_method_codec.h>
#include <mmsystem.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <thread>
#include <vector>

#include "app_windows.h"
#include "stash_ocr.h"
#include "utils.h"

namespace {

// The hot key's id on the main window (WM_HOTKEY's wparam).
constexpr int kHotkeyId = 0x4253;       // 'BS' (Stash)
constexpr int kVoiceHotkeyId = 0x4256;  // 'BV' (Voice)

std::string Lower(std::string text) {
  for (char& c : text) {
    if (c >= 'A' && c <= 'Z') {
      c = static_cast<char>(c - 'A' + 'a');
    }
  }
  return text;
}

std::string Trim(const std::string& text) {
  const size_t start = text.find_first_not_of(" \t");
  if (start == std::string::npos) {
    return std::string();
  }
  const size_t end = text.find_last_not_of(" \t");
  return text.substr(start, end - start + 1);
}

// The virtual key |name| (`a`, `space`, `f5`, `/`…) stands for; 0 for none.
UINT KeyOf(const std::string& name) {
  if (name.size() == 1) {
    const char c = name[0];
    if (c >= 'a' && c <= 'z') {
      return static_cast<UINT>(c - 'a' + 'A');
    }
    if (c >= '0' && c <= '9') {
      return static_cast<UINT>(c);
    }
    // Punctuation, as the keyboard's layout has it.
    const SHORT scan = ::VkKeyScanW(static_cast<wchar_t>(c));
    return scan == -1 ? 0 : static_cast<UINT>(LOBYTE(scan));
  }
  static const std::pair<const char*, UINT> kNamed[] = {
      {"space", VK_SPACE},   {"enter", VK_RETURN}, {"return", VK_RETURN},
      {"tab", VK_TAB},       {"escape", VK_ESCAPE}, {"esc", VK_ESCAPE},
      {"left", VK_LEFT},     {"right", VK_RIGHT},  {"up", VK_UP},
      {"down", VK_DOWN},     {"backquote", VK_OEM_3},
  };
  for (const auto& [named, key] : kNamed) {
    if (name == named) {
      return key;
    }
  }
  if (name.size() >= 2 && name[0] == 'f') {
    const int number = std::atoi(name.c_str() + 1);
    if (number >= 1 && number <= 24) {
      return static_cast<UINT>(VK_F1 + number - 1);
    }
  }
  return 0;
}

}  // namespace

StashChannel::StashChannel(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "baocode/stash",
          &flutter::StandardMethodCodec::GetInstance())),
      voice_channel_(
          std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
              messenger, "baocode/voice",
              &flutter::StandardMethodCodec::GetInstance())) {
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
  voice_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleVoiceMethodCall(call, std::move(result)); });
}

StashChannel::~StashChannel() {
  channel_->SetMethodCallHandler(nullptr);
  voice_channel_->SetMethodCallHandler(nullptr);
  Unregister();
  UnregisterVoice();
  CancelVoiceRecording();
  StopVoiceAudio();
}

std::optional<std::pair<UINT, UINT>> StashChannel::Parse(
    const std::string& spec) {
  UINT modifiers = 0;
  UINT key = 0;
  std::stringstream parts(Lower(spec));
  std::string part;
  while (std::getline(parts, part, '+')) {
    part = Trim(part);
    if (part == "ctrl" || part == "control") {
      modifiers |= MOD_CONTROL;
    } else if (part == "alt" || part == "option" || part == "opt") {
      modifiers |= MOD_ALT;
    } else if (part == "shift") {
      modifiers |= MOD_SHIFT;
    } else if (part == "cmd" || part == "command" || part == "meta" ||
               part == "win" || part == "super") {
      modifiers |= MOD_WIN;
    } else if (!part.empty()) {
      key = KeyOf(part);
    }
  }
  if (key == 0 || modifiers == 0) {
    return std::nullopt;
  }
  return std::make_pair(modifiers, key);
}

bool StashChannel::Register(const std::string& spec) {
  Unregister();
  const auto parsed = Parse(spec);
  if (!parsed) {
    return Trim(spec).empty();
  }
  registered_ = ::RegisterHotKey(window_, kHotkeyId,
                                 parsed->first | MOD_NOREPEAT,
                                 parsed->second) != 0;
  return registered_;
}

void StashChannel::Unregister() {
  if (registered_) {
    ::UnregisterHotKey(window_, kHotkeyId);
    registered_ = false;
  }
}

bool StashChannel::RegisterVoice(const std::string& spec) {
  UnregisterVoice();
  const auto parsed = Parse(spec);
  if (!parsed) {
    return Trim(spec).empty();
  }
  voice_registered_ = ::RegisterHotKey(window_, kVoiceHotkeyId,
                                       parsed->first | MOD_NOREPEAT,
                                       parsed->second) != 0;
  return voice_registered_;
}

void StashChannel::UnregisterVoice() {
  if (voice_registered_) {
    ::UnregisterHotKey(window_, kVoiceHotkeyId);
    voice_registered_ = false;
  }
}

namespace {

constexpr DWORD kVoiceSampleRate = 16000;
constexpr WORD kVoiceChannels = 1;
constexpr WORD kVoiceBitsPerSample = 16;
constexpr int kVoiceBufferCount = 4;
// 200ms per buffer: 16000 Hz * 2 bytes * 0.2s = 6400 bytes.
constexpr DWORD kVoiceBufferBytes =
    (kVoiceSampleRate * (kVoiceBitsPerSample / 8) * kVoiceChannels) / 5;

void WriteLe32(uint8_t* dst, uint32_t value) {
  dst[0] = static_cast<uint8_t>(value & 0xFF);
  dst[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
  dst[2] = static_cast<uint8_t>((value >> 16) & 0xFF);
  dst[3] = static_cast<uint8_t>((value >> 24) & 0xFF);
}

void WriteLe16(uint8_t* dst, uint16_t value) {
  dst[0] = static_cast<uint8_t>(value & 0xFF);
  dst[1] = static_cast<uint8_t>((value >> 8) & 0xFF);
}

void BuildWavHeader(uint8_t header[44], uint32_t data_bytes) {
  std::memcpy(header + 0, "RIFF", 4);
  WriteLe32(header + 4, 36 + data_bytes);
  std::memcpy(header + 8, "WAVE", 4);
  std::memcpy(header + 12, "fmt ", 4);
  WriteLe32(header + 16, 16);  // PCM fmt chunk size
  WriteLe16(header + 20, 1);   // PCM format
  WriteLe16(header + 22, kVoiceChannels);
  WriteLe32(header + 24, kVoiceSampleRate);
  const uint32_t byte_rate =
      kVoiceSampleRate * kVoiceChannels * (kVoiceBitsPerSample / 8);
  WriteLe32(header + 28, byte_rate);
  const uint16_t block_align = kVoiceChannels * (kVoiceBitsPerSample / 8);
  WriteLe16(header + 32, block_align);
  WriteLe16(header + 34, kVoiceBitsPerSample);
  std::memcpy(header + 36, "data", 4);
  WriteLe32(header + 40, data_bytes);
}

std::string WaveErrorString(MMRESULT err) {
  wchar_t buf[256] = {};
  if (::waveInGetErrorTextW(err, buf, 256) == MMSYSERR_NOERROR) {
    return Utf8FromUtf16(buf);
  }
  return "waveIn error " + std::to_string(err);
}

std::string MciPlayErrorString(MCIERROR err) {
  wchar_t buf[256] = {};
  if (::mciGetErrorStringW(err, buf, 256)) {
    return Utf8FromUtf16(buf);
  }
  return "MCI error " + std::to_string(err);
}

// Synthesizes a soft, pleasant in-memory 16kHz mono PCM WAV chime (zero files,
// <0.1ms playback via PlaySoundW SND_MEMORY | SND_ASYNC).
std::vector<uint8_t> BuildEarconWav(const std::string& kind) {
  constexpr double kPi = 3.14159265358979323846;
  struct Tone {
    double freq;
    double ms;
    double amp;
  };
  std::vector<Tone> tones;
  if (kind == "start") {
    tones = {{660.0, 55.0, 0.14}, {880.0, 75.0, 0.16}};
  } else if (kind == "stop") {
    tones = {{780.0, 48.0, 0.13}, {580.0, 62.0, 0.13}};
  } else {
    // exit conversation mode: gentle descending triad
    tones = {{740.0, 55.0, 0.13}, {587.0, 55.0, 0.13}, {440.0, 90.0, 0.14}};
  }
  std::vector<int16_t> samples;
  for (const auto& t : tones) {
    const size_t count =
        static_cast<size_t>((t.ms / 1000.0) * static_cast<double>(kVoiceSampleRate));
    const size_t fade = (std::min)(count / 4, static_cast<size_t>(160));
    for (size_t i = 0; i < count; ++i) {
      double env = 1.0;
      if (i < fade) {
        env = static_cast<double>(i) / static_cast<double>(fade);
      } else if (i + fade > count) {
        env = static_cast<double>(count - i) / static_cast<double>(fade);
      }
      const double phase =
          2.0 * kPi * t.freq * static_cast<double>(i) /
          static_cast<double>(kVoiceSampleRate);
      const double val = std::sin(phase) * t.amp * env;
      samples.push_back(static_cast<int16_t>(val * 32767.0));
    }
  }
  const uint32_t data_bytes = static_cast<uint32_t>(samples.size() * 2);
  std::vector<uint8_t> wav(44 + data_bytes);
  BuildWavHeader(wav.data(), data_bytes);
  if (data_bytes > 0) {
    std::memcpy(wav.data() + 44, samples.data(), data_bytes);
  }
  return wav;
}

}  // namespace

std::string StashChannel::StartVoiceRecording(const std::string& utf8_path,
                                              int device_id) {
  CancelVoiceRecording();
  if (utf8_path.empty()) {
    return "Empty output path";
  }
  voice_recording_path_ = Utf16FromUtf8(utf8_path);

  // Open with FILE_SHARE_READ | FILE_SHARE_WRITE so the streaming recognizer
  // can read flushed PCM samples concurrently while recording is in progress.
  HANDLE file = ::CreateFileW(
      voice_recording_path_.c_str(), GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    voice_recording_path_.clear();
    return "Failed to create WAV file (err=" +
           std::to_string(::GetLastError()) + ")";
  }
  uint8_t header[44] = {};
  BuildWavHeader(header, 0);
  DWORD written = 0;
  ::WriteFile(file, header, sizeof(header), &written, nullptr);
  ::FlushFileBuffers(file);

  HANDLE ev = ::CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (ev == nullptr) {
    ::CloseHandle(file);
    voice_recording_path_.clear();
    return "Failed to create audio event";
  }

  WAVEFORMATEX fmt = {};
  fmt.wFormatTag = WAVE_FORMAT_PCM;
  fmt.nChannels = kVoiceChannels;
  fmt.nSamplesPerSec = kVoiceSampleRate;
  fmt.wBitsPerSample = kVoiceBitsPerSample;
  fmt.nBlockAlign = fmt.nChannels * (fmt.wBitsPerSample / 8);
  fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;

  const UINT dev = device_id < 0 ? WAVE_MAPPER : static_cast<UINT>(device_id);
  HWAVEIN hwi = nullptr;
  MMRESULT res = ::waveInOpen(&hwi, dev, &fmt,
                              reinterpret_cast<DWORD_PTR>(ev), 0,
                              CALLBACK_EVENT);
  if (res != MMSYSERR_NOERROR && dev != WAVE_MAPPER) {
    // Selected device unplugged: gracefully fall back to WAVE_MAPPER.
    res = ::waveInOpen(&hwi, WAVE_MAPPER, &fmt,
                       reinterpret_cast<DWORD_PTR>(ev), 0, CALLBACK_EVENT);
  }
  if (res != MMSYSERR_NOERROR) {
    ::CloseHandle(ev);
    ::CloseHandle(file);
    voice_recording_path_.clear();
    return WaveErrorString(res);
  }

  wave_in_ = hwi;
  wave_event_ = ev;
  wave_file_ = file;
  wave_stop_.store(false);
  wave_data_bytes_.store(0);
  wave_level_milli_.store(0);
  wave_silence_ms_.store(0);
  wave_total_ms_.store(0);
  wave_heard_speech_.store(false);

  wave_thread_ = std::thread([this, hwi, ev, file]() {
    std::vector<std::vector<char>> buffers(
        kVoiceBufferCount, std::vector<char>(kVoiceBufferBytes));
    std::vector<WAVEHDR> headers(kVoiceBufferCount);
    for (int i = 0; i < kVoiceBufferCount; ++i) {
      std::memset(&headers[i], 0, sizeof(WAVEHDR));
      headers[i].lpData = buffers[i].data();
      headers[i].dwBufferLength = kVoiceBufferBytes;
      ::waveInPrepareHeader(hwi, &headers[i], sizeof(WAVEHDR));
      ::waveInAddBuffer(hwi, &headers[i], sizeof(WAVEHDR));
    }
    ::waveInStart(hwi);

    // Adaptive ambient noise floor: calibrate over the first ~250ms, then track
    // slowly during silence so AC/fan hum doesn't keep VAD stuck forever.
    double noise_floor_rms = 0.006;
    uint32_t calibrated_ms = 0;

    auto drain = [&](bool requeue) {
      bool flushed = false;
      for (int i = 0; i < kVoiceBufferCount; ++i) {
        if ((headers[i].dwFlags & WHDR_DONE) != 0) {
          if (headers[i].dwBytesRecorded > 0) {
            DWORD bytes_written = 0;
            ::WriteFile(file, headers[i].lpData, headers[i].dwBytesRecorded,
                        &bytes_written, nullptr);
            wave_data_bytes_.fetch_add(static_cast<uint32_t>(bytes_written));
            flushed = true;

            const size_t sample_count = headers[i].dwBytesRecorded / 2;
            if (sample_count > 0) {
              const auto* pcm =
                  reinterpret_cast<const int16_t*>(headers[i].lpData);
              double sum_sq = 0.0;
              for (size_t s = 0; s < sample_count; ++s) {
                const double norm = static_cast<double>(pcm[s]) / 32768.0;
                sum_sq += norm * norm;
              }
              const double rms =
                  std::sqrt(sum_sq / static_cast<double>(sample_count));
              const uint32_t chunk_ms = static_cast<uint32_t>(
                  (sample_count * 1000) / kVoiceSampleRate);
              wave_total_ms_.fetch_add(chunk_ms);

              if (calibrated_ms < 260) {
                noise_floor_rms =
                    calibrated_ms == 0 ? rms : (noise_floor_rms * 0.5 + rms * 0.5);
                calibrated_ms += chunk_ms;
              }
              const double speech_threshold =
                  (std::max)(0.011, (std::min)(0.085, noise_floor_rms * 2.4));
              const double visual_rms =
                  (std::max)(0.0, rms - noise_floor_rms * 0.7);
              const double scaled = (std::min)(1.0, visual_rms * 6.0);
              wave_level_milli_.store(static_cast<int>(scaled * 1000.0));

              if (rms >= speech_threshold) {
                wave_heard_speech_.store(true);
                wave_silence_ms_.store(0);
              } else {
                // Slowly adapt noise floor downward/upward during quiet frames.
                noise_floor_rms = noise_floor_rms * 0.92 + rms * 0.08;
                if (wave_heard_speech_.load()) {
                  wave_silence_ms_.fetch_add(chunk_ms);
                }
              }
            }
          }
          if (requeue && !wave_stop_.load()) {
            headers[i].dwBytesRecorded = 0;
            ::waveInAddBuffer(hwi, &headers[i], sizeof(WAVEHDR));
          }
        }
      }
      if (flushed) {
        ::FlushFileBuffers(file);
      }
    };

    while (!wave_stop_.load()) {
      ::WaitForSingleObject(ev, 100);
      drain(true);
    }

    // Stop & reset returns any partially filled buffer with WHDR_DONE.
    ::waveInStop(hwi);
    ::waveInReset(hwi);
    drain(false);

    for (int i = 0; i < kVoiceBufferCount; ++i) {
      ::waveInUnprepareHeader(hwi, &headers[i], sizeof(WAVEHDR));
    }
  });

  voice_recording_ = true;
  return "";
}

std::string StashChannel::StopVoiceRecording() {
  if (!voice_recording_) {
    return "Not recording";
  }
  voice_recording_ = false;
  wave_stop_.store(true);
  if (wave_event_ != nullptr) {
    ::SetEvent(wave_event_);
  }
  if (wave_thread_.joinable()) {
    wave_thread_.join();
  }
  if (wave_in_ != nullptr) {
    ::waveInClose(static_cast<HWAVEIN>(wave_in_));
    wave_in_ = nullptr;
  }
  if (wave_event_ != nullptr) {
    ::CloseHandle(wave_event_);
    wave_event_ = nullptr;
  }
  if (wave_file_ != INVALID_HANDLE_VALUE) {
    uint8_t header[44] = {};
    BuildWavHeader(header, wave_data_bytes_.load());
    ::SetFilePointer(wave_file_, 0, nullptr, FILE_BEGIN);
    DWORD written = 0;
    ::WriteFile(wave_file_, header, sizeof(header), &written, nullptr);
    ::FlushFileBuffers(wave_file_);
    ::CloseHandle(wave_file_);
    wave_file_ = INVALID_HANDLE_VALUE;
  }
  voice_recording_path_.clear();
  return "";
}

void StashChannel::CancelVoiceRecording() {
  if (!voice_recording_ && wave_in_ == nullptr &&
      wave_file_ == INVALID_HANDLE_VALUE) {
    return;
  }
  voice_recording_ = false;
  wave_stop_.store(true);
  if (wave_event_ != nullptr) {
    ::SetEvent(wave_event_);
  }
  if (wave_thread_.joinable()) {
    wave_thread_.join();
  }
  if (wave_in_ != nullptr) {
    ::waveInClose(static_cast<HWAVEIN>(wave_in_));
    wave_in_ = nullptr;
  }
  if (wave_event_ != nullptr) {
    ::CloseHandle(wave_event_);
    wave_event_ = nullptr;
  }
  if (wave_file_ != INVALID_HANDLE_VALUE) {
    ::CloseHandle(wave_file_);
    wave_file_ = INVALID_HANDLE_VALUE;
  }
  voice_recording_path_.clear();
}

std::string StashChannel::PlayVoiceAudio(const std::string& utf8_path,
                                         int play_id) {
  StopVoiceAudio();
  if (utf8_path.empty()) {
    return "Empty audio path";
  }
  const std::wstring path = Utf16FromUtf8(utf8_path);
  const std::wstring open_cmd =
      L"open \"" + path + L"\" type mpegvideo alias ayte_tts_play";
  MCIERROR err = ::mciSendStringW(open_cmd.c_str(), nullptr, 0, nullptr);
  if (err != 0) {
    return MciPlayErrorString(err);
  }
  voice_play_device_id_ = ::mciGetDeviceIDW(L"ayte_tts_play");
  voice_play_id_ = play_id;
  voice_playing_ = true;
  voice_paused_ = false;
  err = ::mciSendStringW(L"play ayte_tts_play notify", nullptr, 0, window_);
  if (err != 0) {
    StopVoiceAudio();
    return MciPlayErrorString(err);
  }
  return "";
}

bool StashChannel::PauseVoiceAudio() {
  if (!voice_playing_ || voice_paused_) return false;
  voice_paused_ = true;
  if (::mciSendStringW(L"pause ayte_tts_play", nullptr, 0, nullptr) != 0) {
    voice_paused_ = false;
    return false;
  }
  return true;
}

bool StashChannel::ResumeVoiceAudio() {
  if (!voice_playing_ || !voice_paused_) return false;
  voice_paused_ = false;
  if (::mciSendStringW(L"play ayte_tts_play notify", nullptr, 0, window_) !=
      0) {
    voice_paused_ = true;
    return false;
  }
  return true;
}

void StashChannel::StopVoiceAudio() {
  if (!voice_playing_ && voice_play_device_id_ == 0) {
    return;
  }
  voice_playing_ = false;
  voice_paused_ = false;
  voice_play_device_id_ = 0;
  ::mciSendStringW(L"stop ayte_tts_play", nullptr, 0, nullptr);
  ::mciSendStringW(L"close ayte_tts_play", nullptr, 0, nullptr);
}

bool StashChannel::HandleMciNotify(WPARAM flags, LPARAM device) {
  if (!voice_playing_ || voice_play_device_id_ == 0 ||
      static_cast<UINT>(device) != voice_play_device_id_) {
    return false;
  }
  if (flags == MCI_NOTIFY_ABORTED && voice_paused_) {
    // Pausing aborts the active play notification; keep device open for resume.
    return true;
  }
  if (flags == MCI_NOTIFY_SUPERSEDED) {
    return true;
  }
  const int finished_id = voice_play_id_;
  StopVoiceAudio();
  if (flags == MCI_NOTIFY_SUCCESSFUL || flags == MCI_NOTIFY_FAILURE) {
    voice_channel_->InvokeMethod(
        "playbackDone",
        std::make_unique<flutter::EncodableValue>(finished_id));
  }
  return true;
}

void StashChannel::Post(HWND window, std::function<void()> task) {
  auto* boxed = new std::function<void()>(std::move(task));
  if (!::PostMessageW(window, kRunMessage, 0,
                      reinterpret_cast<LPARAM>(boxed))) {
    delete boxed;
  }
}

void StashChannel::Run(LPARAM task, bool alive) {
  std::unique_ptr<std::function<void()>> boxed(
      reinterpret_cast<std::function<void()>*>(task));
  if (alive && boxed != nullptr && *boxed) {
    (*boxed)();
  }
}

bool StashChannel::HandleHotkey(WPARAM id) {
  if (static_cast<int>(id) == kVoiceHotkeyId) {
    if (::IsIconic(window_)) {
      ::ShowWindow(window_, SW_RESTORE);
    } else if (!::IsWindowVisible(window_)) {
      ::ShowWindow(window_, SW_SHOW);
    }
    ::SetForegroundWindow(window_);
    voice_channel_->InvokeMethod("pressed", nullptr);
    return true;
  }
  if (static_cast<int>(id) != kHotkeyId) {
    return false;
  }
  const HWND front = ::GetForegroundWindow();
  DWORD process = 0;
  if (front != nullptr) {
    ::GetWindowThreadProcessId(front, &process);
  }
  // The panel itself in front: it hides (given the keyboard back
  // otherwise).
  channel_->InvokeMethod(
      "pressed",
      std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("self"),
           flutter::EncodableValue(front != nullptr &&
                                   process == ::GetCurrentProcessId())},
          {flutter::EncodableValue("panel"),
           flutter::EncodableValue(front != nullptr &&
                                   front == AppWindows::StashHandle())},
      }));
  return true;
}

void StashChannel::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* text = call.arguments() == nullptr
                         ? nullptr
                         : std::get_if<std::string>(call.arguments());
  if (method == "setHotkey") {
    result->Success(
        flutter::EncodableValue(Register(text == nullptr ? "" : *text)));
    return;
  }
  if (method == "recognizeText") {
    if (text == nullptr || text->empty()) {
      result->Success();
      return;
    }
    // Read in the background; answered on the platform thread.
    std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>> shared(
        std::move(result));
    const std::wstring path = Utf16FromUtf8(*text);
    const HWND owner = window_;
    std::thread([shared, path, owner]() {
      const std::optional<std::wstring> found = stash_ocr::Recognize(path);
      Post(owner, [shared, found]() {
        if (found) {
          shared->Success(
              flutter::EncodableValue(Utf8FromUtf16(found->c_str())));
        } else {
          shared->Success();
        }
      });
    }).detach();
    return;
  }
  result->NotImplemented();
}

void StashChannel::HandleVoiceMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* text = call.arguments() == nullptr
                         ? nullptr
                         : std::get_if<std::string>(call.arguments());
  if (method == "setHotkey") {
    result->Success(
        flutter::EncodableValue(RegisterVoice(text == nullptr ? "" : *text)));
    return;
  }
  if (method == "startRecording") {
    std::string path;
    int device_id = -1;
    if (text != nullptr) {
      path = *text;
    } else if (call.arguments() != nullptr) {
      if (const auto* map =
              std::get_if<flutter::EncodableMap>(call.arguments())) {
        const auto p_it = map->find(flutter::EncodableValue("path"));
        if (p_it != map->end()) {
          if (const auto* s = std::get_if<std::string>(&p_it->second)) {
            path = *s;
          }
        }
        const auto d_it = map->find(flutter::EncodableValue("deviceId"));
        if (d_it != map->end()) {
          if (const auto* i = std::get_if<int32_t>(&d_it->second)) {
            device_id = *i;
          }
        }
      }
    }
    const std::string err = StartVoiceRecording(path, device_id);
    if (err.empty()) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("MCI_RECORD_START", err);
    }
    return;
  }
  if (method == "listInputDevices") {
    flutter::EncodableList list;
    const UINT count = ::waveInGetNumDevs();
    for (UINT i = 0; i < count; ++i) {
      WAVEINCAPSW caps = {};
      if (::waveInGetDevCapsW(i, &caps, sizeof(caps)) == MMSYSERR_NOERROR) {
        list.push_back(flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("id"),
             flutter::EncodableValue(static_cast<int32_t>(i))},
            {flutter::EncodableValue("name"),
             flutter::EncodableValue(Utf8FromUtf16(caps.szPname))},
        }));
      }
    }
    result->Success(flutter::EncodableValue(list));
    return;
  }
  if (method == "playAudio") {
    std::string path;
    int play_id = 0;
    if (call.arguments() != nullptr) {
      if (const auto* map =
              std::get_if<flutter::EncodableMap>(call.arguments())) {
        const auto p_it = map->find(flutter::EncodableValue("path"));
        if (p_it != map->end()) {
          if (const auto* s = std::get_if<std::string>(&p_it->second)) {
            path = *s;
          }
        }
        const auto id_it = map->find(flutter::EncodableValue("id"));
        if (id_it != map->end()) {
          if (const auto* i = std::get_if<int32_t>(&id_it->second)) {
            play_id = *i;
          }
        }
      }
    }
    const std::string err = PlayVoiceAudio(path, play_id);
    if (err.empty()) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("MCI_PLAY", err);
    }
    return;
  }
  if (method == "pauseAudio") {
    result->Success(flutter::EncodableValue(PauseVoiceAudio()));
    return;
  }
  if (method == "resumeAudio") {
    result->Success(flutter::EncodableValue(ResumeVoiceAudio()));
    return;
  }
  if (method == "stopAudio") {
    StopVoiceAudio();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "playEarcon") {
    earcon_wav_ = BuildEarconWav(text == nullptr ? "start" : *text);
    if (!earcon_wav_.empty()) {
      ::PlaySoundW(reinterpret_cast<LPCWSTR>(earcon_wav_.data()), nullptr,
                   SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "stopRecording") {
    const std::string err = StopVoiceRecording();
    if (err.empty()) {
      result->Success(flutter::EncodableValue(true));
    } else {
      result->Error("MCI_RECORD_STOP", err);
    }
    return;
  }
  if (method == "cancelRecording") {
    CancelVoiceRecording();
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == "recordingMetrics") {
    result->Success(
        flutter::EncodableValue(flutter::EncodableMap{
            {flutter::EncodableValue("level"),
             flutter::EncodableValue(
                 static_cast<double>(wave_level_milli_.load()) / 1000.0)},
            {flutter::EncodableValue("silenceMs"),
             flutter::EncodableValue(
                 static_cast<int>(wave_silence_ms_.load()))},
            {flutter::EncodableValue("totalMs"),
             flutter::EncodableValue(static_cast<int>(wave_total_ms_.load()))},
            {flutter::EncodableValue("heardSpeech"),
             flutter::EncodableValue(wave_heard_speech_.load())},
        }));
    return;
  }
  if (method == "triggerDictation") {
    // Release any modifier keys still held (e.g. Alt+Shift from the global
    // hotkey) before synthesizing Win+H for Windows 11 neural Voice Typing.
    std::vector<INPUT> inputs;
    auto push_key = [&inputs](WORD vk, bool up) {
      INPUT in = {};
      in.type = INPUT_KEYBOARD;
      in.ki.wVk = vk;
      in.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
      inputs.push_back(in);
    };
    const WORD modifiers[] = {VK_LMENU,   VK_RMENU,    VK_LSHIFT,
                              VK_RSHIFT,  VK_LCONTROL, VK_RCONTROL,
                              VK_RWIN};
    for (WORD vk : modifiers) {
      if ((::GetAsyncKeyState(vk) & 0x8000) != 0) {
        push_key(vk, true);
      }
    }
    push_key(VK_LWIN, false);
    push_key('H', false);
    push_key('H', true);
    push_key(VK_LWIN, true);
    const UINT sent = ::SendInput(static_cast<UINT>(inputs.size()),
                                  inputs.data(), sizeof(INPUT));
    result->Success(flutter::EncodableValue(sent == inputs.size()));
    return;
  }
  result->NotImplemented();
}
