#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

struct AVPacket;

namespace brutv {

// Encoded live packets stay in private, immediately unlinked temporary files.
// One producer may append while a decoder reads or seeks independently.
class PacketSpool {
public:
    struct Limits {
        double seconds = 600.0;
        std::size_t bytes = 256U * 1024U * 1024U;
    };
    struct Snapshot {
        double startSeconds = 0.0;
        double endSeconds = 0.0;
        std::size_t bytes = 0;
        bool finished = false;
    };
    enum class ReadResult { Ready, Waiting, Expired, Finished };

    PacketSpool();
    explicit PacketSpool(Limits limits, std::string directory = {});
    ~PacketSpool();
    PacketSpool(const PacketSpool&) = delete;
    PacketSpool& operator=(const PacketSpool&) = delete;

    // Pass true only for a keyframe from the selected video stream (or every
    // audio packet for an audio-only source). Packets before that point are
    // ignored. False means the packet cannot fit the configured storage cap.
    // timelineSeconds is the producer's nondecreasing normalized live clock.
    // File failures throw without including source addresses or credentials.
    bool append(const AVPacket* packet, double timelineSeconds, bool videoKeyframe);

    // Zero starts at the oldest retained keyframe. Ready advances the cursor;
    // Expired moves it to the oldest retained keyframe without reading it.
    ReadResult read(std::uint64_t& cursor, AVPacket* packet);
    std::uint64_t seek(double targetSeconds) const;
    Snapshot snapshot() const;

    // Marks producer EOF. Retained packets remain readable until destruction.
    void close();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace brutv
