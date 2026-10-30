#include "brutv/timeshift.hpp"

extern "C" {
#include <libavcodec/packet.h>
#include <libavutil/mem.h>
}

#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <thread>
#include <unistd.h>

namespace {

void require(bool condition, const char* message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

struct Packet {
    AVPacket* value = av_packet_alloc();
    ~Packet() { av_packet_free(&value); }
    Packet() {
        if (!value) {
            throw std::runtime_error("Cannot allocate test packet.");
        }
    }
    void fill(int size, int number, bool keyframe) {
        av_packet_unref(value);
        require(av_new_packet(value, size) == 0, "Cannot allocate packet payload.");
        std::memset(value->data, number & 0xff, static_cast<std::size_t>(size));
        value->pts = number * 1000;
        value->dts = number * 1000 - 50;
        value->duration = 100;
        value->pos = number * 200;
        value->stream_index = 3;
        value->flags = keyframe ? AV_PKT_FLAG_KEY : 0;
        value->time_base = {1, 1000};
    }
};

void packetRoundTrip() {
    brutv::PacketSpool spool;
    Packet source;
    Packet output;
    std::uint64_t cursor = 0;
    require(spool.read(cursor, output.value) == brutv::PacketSpool::ReadResult::Waiting,
            "Empty live spool should wait.");
    source.fill(128, 7, true);
    auto* side = av_packet_new_side_data(source.value, AV_PKT_DATA_NEW_EXTRADATA, 4);
    require(side != nullptr, "Cannot allocate test side data.");
    std::memcpy(side, "test", 4);
    require(spool.append(source.value, 7.0, true), "Packet was rejected.");
    require(spool.read(cursor, output.value) == brutv::PacketSpool::ReadResult::Ready,
            "Stored packet was not readable.");
    require(output.value->size == source.value->size &&
            std::memcmp(output.value->data, source.value->data, 128) == 0,
            "Encoded packet bytes changed.");
    require(output.value->pts == source.value->pts && output.value->dts == source.value->dts &&
            output.value->duration == 100 && output.value->pos == source.value->pos &&
            output.value->stream_index == 3 && output.value->flags == AV_PKT_FLAG_KEY &&
            output.value->time_base.num == 1 && output.value->time_base.den == 1000,
            "Packet timing or stream metadata changed.");
    std::size_t sideSize = 0;
    const auto* restored = av_packet_get_side_data(output.value, AV_PKT_DATA_NEW_EXTRADATA, &sideSize);
    require(sideSize == 4 && restored && std::memcmp(restored, "test", 4) == 0,
            "Decoder side data was not preserved.");
    spool.close();
    cursor = spool.seek(7.0);
    require(spool.read(cursor, output.value) == brutv::PacketSpool::ReadResult::Ready,
            "Closing capture discarded readable history.");
    require(spool.read(cursor, output.value) == brutv::PacketSpool::ReadResult::Finished,
            "Drained capture did not reach EOF.");
}

void retentionAndSeeking() {
    brutv::PacketSpool spool({2.0, 8192});
    Packet source;
    Packet output;
    source.fill(80, 0, false);
    require(spool.append(source.value, 0.0, false), "Initial non-keyframe append failed.");
    require(spool.snapshot().bytes == 0, "History began with an undecodable non-keyframe.");
    for (int second = 0; second < 5; ++second) {
        source.fill(80, second, true);
        require(spool.append(source.value, second, true), "Keyframe append failed.");
        source.fill(80, second, false);
        require(spool.append(source.value, second + 0.3, false), "Inter-frame append failed.");
        const auto status = spool.snapshot();
        require(status.endSeconds - status.startSeconds <= 2.0 && status.bytes <= 8192,
                "Retention exceeded its time or byte cap.");
    }
    std::uint64_t expired = 1;
    require(spool.read(expired, output.value) == brutv::PacketSpool::ReadResult::Expired,
            "Overwritten pause cursor was not reported as expired.");
    require(spool.read(expired, output.value) == brutv::PacketSpool::ReadResult::Ready &&
            (output.value->flags & AV_PKT_FLAG_KEY),
            "Expired playback did not restart on a retained keyframe.");
    auto cursor = spool.seek(3.7);
    require(spool.read(cursor, output.value) == brutv::PacketSpool::ReadResult::Ready &&
            output.value->pts == 3000,
            "Seeking did not choose the preceding retained keyframe.");
}

void byteCapAndCleanup() {
    std::string pattern = (std::filesystem::temp_directory_path() / "brutv-spool-test-XXXXXX").string();
    require(::mkdtemp(pattern.data()) != nullptr, "Cannot create the test directory.");
    const auto directory = std::filesystem::path(pattern);
#ifdef __linux__
    const auto openDescriptors = [] {
        return std::distance(std::filesystem::directory_iterator("/proc/self/fd"),
                             std::filesystem::directory_iterator{});
    };
    const auto descriptorsBefore = openDescriptors();
#endif
    try {
        {
            brutv::PacketSpool spool({600.0, 512}, directory.string());
            Packet source;
            for (int index = 0; index < 100; ++index) {
                source.fill(120, index, index % 4 == 0);
                require(spool.append(source.value, index * 0.1, index % 4 == 0),
                        "Bounded packet append failed.");
                require(spool.snapshot().bytes <= 512, "Disk spool exceeded its byte cap.");
                require(std::filesystem::is_empty(directory),
                        "Encoded video remained visible as a named temporary file.");
            }
            source.fill(1024, 101, true);
            require(!spool.append(source.value, 10.1, true), "Oversized packet was accepted.");
        }
        require(std::filesystem::is_empty(directory), "Session destruction left temporary files.");
#ifdef __linux__
        require(openDescriptors() == descriptorsBefore,
                "Session destruction leaked temporary file descriptors.");
#endif
    } catch (...) {
        std::filesystem::remove_all(directory);
        throw;
    }
    std::filesystem::remove(directory);
}

void concurrentCapture() {
    brutv::PacketSpool spool({10.0, 1024U * 1024U});
    std::atomic<bool> producerFailed{false};
    std::thread producer([&] {
        try {
            Packet source;
            for (int index = 0; index < 1000; ++index) {
                source.fill(120, index, index % 20 == 0);
                if (!spool.append(source.value, index * 0.01, index % 20 == 0)) {
                    producerFailed = true;
                }
            }
        } catch (...) {
            producerFailed = true;
        }
        spool.close();
    });
    Packet output;
    std::uint64_t cursor = 0;
    std::size_t count = 0;
    while (true) {
        const auto result = spool.read(cursor, output.value);
        if (result == brutv::PacketSpool::ReadResult::Ready) {
            ++count;
        } else if (result == brutv::PacketSpool::ReadResult::Finished) {
            break;
        } else {
            std::this_thread::yield();
        }
    }
    producer.join();
    require(!producerFailed && count == 1000, "Concurrent capture lost unexpired packets.");
}

} // namespace

int main() {
    try {
        packetRoundTrip();
        retentionAndSeeking();
        byteCapAndCleanup();
        concurrentCapture();
        std::cout << "Live packet retention, keyframe seeking, metadata, privacy and concurrent capture passed.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
