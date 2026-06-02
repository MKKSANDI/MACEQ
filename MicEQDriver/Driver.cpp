// Copyright (c) MicEQ contributors
// Licensed under MIT

#include <aspl/Driver.hpp>

#include <CoreAudio/AudioServerPlugIn.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <vector>

namespace {

constexpr UInt32 SampleRate = 48000;
constexpr UInt32 ChannelCount = 1;
constexpr UInt64 BufferFrames = 2048; // keep small to avoid accidental long-latency buffering

static AudioStreamBasicDescription MakeFloat32InterleavedASBD()
{
    AudioStreamBasicDescription asbd = {};
    asbd.mSampleRate = SampleRate;
    asbd.mFormatID = kAudioFormatLinearPCM;
    asbd.mFormatFlags =
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    asbd.mBitsPerChannel = 32;
    asbd.mChannelsPerFrame = ChannelCount;
    asbd.mFramesPerPacket = 1;
    asbd.mBytesPerFrame = (asbd.mBitsPerChannel / 8) * asbd.mChannelsPerFrame;
    asbd.mBytesPerPacket = asbd.mBytesPerFrame;
    return asbd;
}

class LoopbackBuffer
{
public:
    LoopbackBuffer()
        : data_(BufferFrames * ChannelCount, 0.0f)
    {
    }

    void Reset()
    {
        std::fill(data_.begin(), data_.end(), 0.0f);
        baseFrame_.store(0, std::memory_order_release);
        endFrame_.store(0, std::memory_order_release);
    }

    void Write(UInt64 startFrame, const Float32* frames, UInt32 frameCount)
    {
        if (frameCount == 0) {
            return;
        }

        // Keep only the newest BufferFrames worth of samples.
        if (UInt64(frameCount) > BufferFrames) {
            const UInt32 skip = frameCount - UInt32(BufferFrames);
            startFrame += skip;
            frames += UInt64(skip) * ChannelCount;
            frameCount = UInt32(BufferFrames);
        }

        UInt64 endFrame = startFrame + frameCount;
        UInt64 newBase = endFrame > BufferFrames ? endFrame - BufferFrames : 0;

        // Drop any samples that are older than the new base.
        if (startFrame < newBase) {
            const UInt64 drop = newBase - startFrame;
            if (drop >= frameCount) {
                baseFrame_.store(newBase, std::memory_order_release);
                endFrame_.store(endFrame, std::memory_order_release);
                return;
            }
            startFrame = newBase;
            frames += drop * ChannelCount;
            frameCount -= UInt32(drop);
        }

        for (UInt32 i = 0; i < frameCount; i++) {
            const UInt64 frame = startFrame + i;
            const UInt64 idx = (frame % BufferFrames) * ChannelCount;

            // Interleaved, but we keep ChannelCount=1 by default.
            for (UInt32 ch = 0; ch < ChannelCount; ch++) {
                data_[idx + ch] = frames[UInt64(i) * ChannelCount + ch];
            }
        }

        baseFrame_.store(newBase, std::memory_order_release);
        endFrame_.store(endFrame, std::memory_order_release);
    }

    void Read(UInt64 startFrame, Float32* outFrames, UInt32 frameCount)
    {
        const UInt64 base = baseFrame_.load(std::memory_order_acquire);
        const UInt64 end = endFrame_.load(std::memory_order_acquire);

        for (UInt32 i = 0; i < frameCount; i++) {
            const UInt64 frame = startFrame + i;
            const UInt64 outIdx = UInt64(i) * ChannelCount;

            if (frame < base || frame >= end) {
                for (UInt32 ch = 0; ch < ChannelCount; ch++) {
                    outFrames[outIdx + ch] = 0.0f;
                }
                continue;
            }

            const UInt64 idx = (frame % BufferFrames) * ChannelCount;
            for (UInt32 ch = 0; ch < ChannelCount; ch++) {
                outFrames[outIdx + ch] = data_[idx + ch];
            }
        }
    }

private:
    std::vector<Float32> data_;
    std::atomic<UInt64> baseFrame_{0};
    std::atomic<UInt64> endFrame_{0};
};

class MicEQHandler : public aspl::ControlRequestHandler, public aspl::IORequestHandler
{
public:
    OSStatus OnStartIO() override
    {
        buffer_.Reset();
        return kAudioHardwareNoError;
    }

    void OnStopIO() override
    {
        buffer_.Reset();
    }

    void OnWriteMixedOutput(const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 timestamp,
        const void* bytes,
        UInt32 bytesCount) override
    {
        const UInt64 startFrame = UInt64(timestamp);
        const UInt32 frameCount = bytesCount / (sizeof(Float32) * ChannelCount);

        buffer_.Write(startFrame, static_cast<const Float32*>(bytes), frameCount);
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& /*client*/,
        const std::shared_ptr<aspl::Stream>& /*stream*/,
        Float64 /*zeroTimestamp*/,
        Float64 timestamp,
        void* bytes,
        UInt32 bytesCount) override
    {
        const UInt64 startFrame = UInt64(timestamp);
        const UInt32 frameCount = bytesCount / (sizeof(Float32) * ChannelCount);

        buffer_.Read(startFrame, static_cast<Float32*>(bytes), frameCount);
    }

private:
    LoopbackBuffer buffer_;
};

std::shared_ptr<aspl::Driver> CreateMicEQDriver()
{
    auto context = std::make_shared<aspl::Context>();

    aspl::DeviceParameters deviceParams;
    deviceParams.Name = "MicEQ";
    deviceParams.Manufacturer = "MicEQ";
    deviceParams.DeviceUID = "com.miceq.driver.device";
    deviceParams.ModelUID = "com.miceq.driver";
    deviceParams.ConfigurationApplicationBundleID = "com.macq.app";
    deviceParams.SampleRate = SampleRate;
    deviceParams.ChannelCount = ChannelCount;
    deviceParams.EnableMixing = true;
    deviceParams.ZeroTimeStampPeriod = 512; // ~10.7ms @48kHz; avoids 1s default period
    deviceParams.SafetyOffset = 32;

    auto device = std::make_shared<aspl::Device>(context, deviceParams);

    aspl::StreamParameters inParams;
    inParams.Direction = aspl::Direction::Input;
    inParams.StartingChannel = 1;
    inParams.Format = MakeFloat32InterleavedASBD();

    aspl::StreamParameters outParams = inParams;
    outParams.Direction = aspl::Direction::Output;

    device->AddStreamWithControlsAsync(inParams);
    device->AddStreamWithControlsAsync(outParams);

    auto handler = std::make_shared<MicEQHandler>();
    device->SetControlHandler(handler);
    device->SetIOHandler(handler);

    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);

    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* MicEQEntryPoint(CFAllocatorRef allocator, CFUUIDRef typeUUID)
{
    (void)allocator;

    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) {
        return nullptr;
    }

    static std::shared_ptr<aspl::Driver> driver = CreateMicEQDriver();
    return driver->GetReference();
}
