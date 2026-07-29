#include "audio.h"

#include <mmreg.h>
#include <audioclient.h>
#include <mmdeviceapi.h>
#include <objbase.h>
#include "log.h"

#include <algorithm>
#include <cstring>
#include <vector>


namespace solstream::media {
namespace {

constexpr int kPacketMs = 5;

template <typename T>
void Release(T*& p) {
    if (p) { p->Release(); p = nullptr; }
}

int16_t Clamp16(float value) {
    const float scaled = value * 32767.0f;
    if (scaled > 32767.0f) { return 32767; }
    if (scaled < -32768.0f) { return -32768; }
    return (int16_t) scaled;
}

/// Convert whatever the endpoint's mix format is into interleaved stereo S16.
///
/// The mix format is float32 on every machine this has been run on, but it is
/// not guaranteed to be, and a host that assumes it produces white noise rather
/// than an error -- which is the worst possible way to be wrong about audio.
void Convert(const WAVEFORMATEX* format, const unsigned char* source, UINT32 frames,
             std::vector<int16_t>& out) {
    const int channels = format->nChannels;
    out.resize((size_t) frames * 2);

    // The extensible subformat GUID's first word IS the old format tag --
    // {00000003-0000-0010-8000-00aa00389b71} is IEEE float -- so this needs
    // neither ksmedia.h nor a GUID comparison to answer the only question here.
    const bool isFloat =
        format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT
        || (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE
            && ((const WAVEFORMATEXTENSIBLE*) format)->SubFormat.Data1
                   == WAVE_FORMAT_IEEE_FLOAT);

    for (UINT32 i = 0; i < frames; ++i) {
        float left = 0.0f, right = 0.0f;
        if (isFloat && format->wBitsPerSample == 32) {
            const float* samples = (const float*) source + (size_t) i * channels;
            left = samples[0];
            right = channels > 1 ? samples[1] : samples[0];
        } else if (format->wBitsPerSample == 16) {
            const int16_t* samples = (const int16_t*) source + (size_t) i * channels;
            left = samples[0] / 32768.0f;
            right = channels > 1 ? samples[1] / 32768.0f : left;
        } else if (format->wBitsPerSample == 32) {
            const int32_t* samples = (const int32_t*) source + (size_t) i * channels;
            left = (float) samples[0] / 2147483648.0f;
            right = channels > 1 ? (float) samples[1] / 2147483648.0f : left;
        }
        out[(size_t) i * 2] = Clamp16(left);
        out[(size_t) i * 2 + 1] = Clamp16(right);
    }
}

}  // namespace

void AudioCapture::Stop() { stop_.store(true); }

void AudioCapture::Run(Sink sink, std::function<bool()> keepGoing) {
    stop_.store(false);
    const HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    const bool ownsCom = SUCCEEDED(com);

    IMMDeviceEnumerator* enumerator = nullptr;
    IMMDevice* device = nullptr;
    IAudioClient* client = nullptr;
    IAudioCaptureClient* capture = nullptr;
    WAVEFORMATEX* format = nullptr;

    HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                  __uuidof(IMMDeviceEnumerator), (void**) &enumerator);
    if (SUCCEEDED(hr)) {
        hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    }
    if (SUCCEEDED(hr)) {
        hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, (void**) &client);
    }
    if (SUCCEEDED(hr)) {
        hr = client->GetMixFormat(&format);
    }
    if (SUCCEEDED(hr)) {
        // LOOPBACK, so what is captured is what the speakers are being sent --
        // including the audio of the application being streamed, which is the
        // whole point. A 200 ms buffer is far more than the 5 ms packets need
        // and costs nothing, because it is drained every poll.
        hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
                                2000000, 0, format, nullptr);
    }
    if (SUCCEEDED(hr)) {
        hr = client->GetService(__uuidof(IAudioCaptureClient), (void**) &capture);
    }
    if (SUCCEEDED(hr)) {
        hr = client->Start();
    }
    if (FAILED(hr)) {
        Log("[media] audio loopback unavailable (0x%08lX); streaming video only", hr);
        Release(capture);
        Release(client);
        Release(device);
        Release(enumerator);
        if (format) { CoTaskMemFree(format); }
        if (ownsCom) { CoUninitialize(); }
        return;
    }

    started_.store(true);
    Log("[media] audio loopback at %lu Hz, %u channels, %u bits",
        format->nSamplesPerSec, format->nChannels, format->wBitsPerSample);

    const uint32_t rate = format->nSamplesPerSec;
    const size_t framesPerPacket = (size_t) rate * kPacketMs / 1000;

    LARGE_INTEGER frequency{}, started{};
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&started);

    std::vector<int16_t> converted, pending;
    uint32_t seq = 1;

    while (!stop_.load() && keepGoing()) {
        UINT32 available = 0;
        if (FAILED(capture->GetNextPacketSize(&available)) || available == 0) {
            Sleep(kPacketMs);
            continue;
        }
        while (available > 0) {
            BYTE* data = nullptr;
            UINT32 frames = 0;
            DWORD flags = 0;
            if (FAILED(capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr))) {
                break;
            }
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                // Nothing is playing. Sending digital silence would cost 1.5
                // Mbit/s to transmit nothing; the Mac plays silence when its
                // queue runs dry, which is the same result for no bytes.
                ++silent_;
            } else if (frames > 0) {
                Convert(format, data, frames, converted);
                pending.insert(pending.end(), converted.begin(), converted.end());
            }
            capture->ReleaseBuffer(frames);
            if (FAILED(capture->GetNextPacketSize(&available))) {
                break;
            }
        }

        while (pending.size() >= framesPerPacket * 2) {
            LARGE_INTEGER now{};
            QueryPerformanceCounter(&now);
            const uint32_t timestampUs = (uint32_t)
                ((now.QuadPart - started.QuadPart) * 1000000 / frequency.QuadPart);
            sink((const unsigned char*) pending.data(), framesPerPacket * 2 * sizeof(int16_t),
                 seq++, timestampUs, rate, 2);
            packets_.fetch_add(1);
            pending.erase(pending.begin(), pending.begin() + framesPerPacket * 2);
        }
    }

    client->Stop();
    started_.store(false);
    Release(capture);
    Release(client);
    Release(device);
    Release(enumerator);
    if (format) { CoTaskMemFree(format); }
    if (ownsCom) { CoUninitialize(); }
}

}  // namespace solstream::media
