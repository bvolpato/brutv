// SPDX-License-Identifier: MIT
#include "brutv/timeshift.hpp"

extern "C" {
#include <libavcodec/packet.h>
}

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstring>
#include <deque>
#include <filesystem>
#include <limits>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>
#include <sys/stat.h>
#include <unistd.h>

namespace brutv {
namespace {

constexpr std::size_t kMaxChunks = 128;
constexpr std::size_t kMaxRecords = 262144;
constexpr int kMaxSideData = 64;
constexpr std::size_t kWriteBatchBytes = 128U * 1024U;
constexpr std::size_t kHotRingMaxBytes = 3U * 1024U * 1024U;

struct PacketHeader {
    std::int64_t pts = 0;
    std::int64_t dts = 0;
    std::int64_t duration = 0;
    std::int64_t pos = 0;
    int stream = 0;
    int flags = 0;
    int size = 0;
    int sideCount = 0;
    int timeBaseNum = 0;
    int timeBaseDen = 0;
};

struct SideHeader {
    std::uint64_t size = 0;
    int type = 0;
};

void pwriteAll(int fd, const void* data, std::size_t bytes, std::size_t offset) {
    const auto* position = static_cast<const char*>(data);
    while (bytes > 0) {
        const auto count = ::pwrite(fd, position, bytes, static_cast<off_t>(offset));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            throw std::runtime_error("Cannot write the temporary live buffer.");
        }
        position += count;
        offset += static_cast<std::size_t>(count);
        bytes -= static_cast<std::size_t>(count);
    }
}

void preadAll(int fd, void* data, std::size_t bytes, std::size_t offset) {
    auto* position = static_cast<char*>(data);
    while (bytes > 0) {
        const auto count = ::pread(fd, position, bytes, static_cast<off_t>(offset));
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            throw std::runtime_error("Cannot read the temporary live buffer.");
        }
        position += count;
        offset += static_cast<std::size_t>(count);
        bytes -= static_cast<std::size_t>(count);
    }
}

void serializePacket(const AVPacket* packet, std::size_t totalSize, std::vector<std::uint8_t>& out) {
    out.resize(totalSize);
    PacketHeader header{};
    header.pts = packet->pts;
    header.dts = packet->dts;
    header.duration = packet->duration;
    header.pos = packet->pos;
    header.stream = packet->stream_index;
    header.flags = packet->flags;
    header.size = packet->size;
    header.sideCount = packet->side_data_elems;
    header.timeBaseNum = packet->time_base.num;
    header.timeBaseDen = packet->time_base.den;

    std::size_t offset = 0;
    std::memcpy(out.data() + offset, &header, sizeof(header));
    offset += sizeof(header);
    if (packet->size > 0) {
        std::memcpy(out.data() + offset, packet->data, static_cast<std::size_t>(packet->size));
        offset += static_cast<std::size_t>(packet->size);
    }
    for (int index = 0; index < packet->side_data_elems; ++index) {
        const auto& side = packet->side_data[index];
        SideHeader sideHeader{};
        sideHeader.size = side.size;
        sideHeader.type = side.type;
        std::memcpy(out.data() + offset, &sideHeader, sizeof(sideHeader));
        offset += sizeof(sideHeader);
        if (side.size > 0) {
            std::memcpy(out.data() + offset, side.data, side.size);
            offset += side.size;
        }
    }
}

void deserializePacket(const std::uint8_t* data, std::size_t totalSize, AVPacket* packet) {
    if (totalSize < sizeof(PacketHeader)) {
        throw std::runtime_error("Corrupted live buffer packet header.");
    }
    PacketHeader header{};
    std::memcpy(&header, data, sizeof(header));
    std::size_t offset = sizeof(header);
    if (header.size < 0 || static_cast<std::size_t>(header.size) > totalSize - offset ||
        header.sideCount < 0 || header.sideCount > kMaxSideData) {
        throw std::runtime_error("Corrupted live buffer packet payload.");
    }
    av_packet_unref(packet);
    if (av_new_packet(packet, header.size) < 0) {
        throw std::runtime_error("Cannot allocate a live buffer packet.");
    }
    try {
        if (header.size > 0) {
            std::memcpy(packet->data, data + offset, static_cast<std::size_t>(header.size));
            offset += static_cast<std::size_t>(header.size);
        }
        packet->pts = header.pts;
        packet->dts = header.dts;
        packet->duration = header.duration;
        packet->pos = header.pos;
        packet->stream_index = header.stream;
        packet->flags = header.flags;
        packet->time_base = {header.timeBaseNum, header.timeBaseDen};
        for (int index = 0; index < header.sideCount; ++index) {
            if (sizeof(SideHeader) > totalSize - offset) {
                throw std::runtime_error("Corrupted live buffer side data header.");
            }
            SideHeader side{};
            std::memcpy(&side, data + offset, sizeof(side));
            offset += sizeof(side);
            if (side.size > totalSize - offset) {
                throw std::runtime_error("Corrupted live buffer side data payload.");
            }
            auto* bytes = av_packet_new_side_data(
                packet, static_cast<AVPacketSideDataType>(side.type),
                static_cast<std::size_t>(side.size));
            if (!bytes) {
                throw std::runtime_error("Cannot allocate live buffer packet metadata.");
            }
            if (side.size > 0) {
                std::memcpy(bytes, data + offset, static_cast<std::size_t>(side.size));
                offset += static_cast<std::size_t>(side.size);
            }
        }
    } catch (...) {
        av_packet_unref(packet);
        throw;
    }
}

struct Chunk {
    struct Record {
        std::uint64_t sequence = 0;
        std::size_t offset = 0;
        std::size_t size = 0;
        double seconds = 0.0;
        bool keyframe = false;
    };
    int fd = -1;
    std::size_t bytes = 0;
    std::size_t flushedBytes = 0;
    std::vector<std::uint8_t> writeBuf;
    std::vector<Record> records;
    std::vector<std::size_t> keyframes;
    bool sealed = false;

    explicit Chunk(const std::string& directory) {
        std::string pattern = directory + "/brutv-rewind-XXXXXX";
        std::vector<char> name(pattern.begin(), pattern.end());
        name.push_back('\0');
        fd = ::mkstemp(name.data());
        if (fd < 0) {
            throw std::runtime_error("Cannot create temporary storage for live rewind.");
        }
        const bool privateFile =
            ::fchmod(fd, S_IRUSR | S_IWUSR) == 0 || errno == ENOSYS || errno == EPERM;
        const bool unlinked = ::unlink(name.data()) == 0;
        if (!privateFile || !unlinked) {
            ::close(fd);
            fd = -1;
            (void)::unlink(name.data());
            throw std::runtime_error("Cannot secure temporary storage for live rewind.");
        }
        records.reserve(512);
    }

    void flush() {
        if (writeBuf.empty()) {
            return;
        }
        pwriteAll(fd, writeBuf.data(), writeBuf.size(), flushedBytes);
        flushedBytes += writeBuf.size();
        writeBuf.clear();
    }

    void seal() {
        flush();
        writeBuf.shrink_to_fit();
        sealed = true;
    }

    ~Chunk() {
        if (fd >= 0) {
            ::close(fd);
        }
    }
};

struct HotPacket {
    std::uint64_t sequence = 0;
    std::shared_ptr<std::vector<std::uint8_t>> data;
};

} // namespace

struct PacketSpool::Impl {
    Limits limits;
    std::string directory;
    double chunkSeconds = 8.0;
    std::size_t writeBatchBytes = kWriteBatchBytes;
    std::size_t hotLimitBytes = kHotRingMaxBytes;
    mutable std::mutex mutex;
    std::deque<std::shared_ptr<Chunk>> chunks;
    std::deque<HotPacket> hotRing;
    std::size_t hotBytes = 0;
    std::size_t bytes = 0;
    std::size_t records = 0;
    std::uint64_t nextSequence = 1;
    double endSeconds = 0.0;
    bool finished = false;

    Impl(Limits requested, std::string temporary)
        : limits(requested), directory(std::move(temporary)) {
        if (!std::isfinite(limits.seconds) || limits.seconds <= 0.0 ||
            limits.bytes < sizeof(PacketHeader) + 1 ||
            limits.bytes > static_cast<std::size_t>(std::numeric_limits<off_t>::max())) {
            throw std::invalid_argument("Invalid live buffer limits.");
        }
        chunkSeconds = std::min(8.0, limits.seconds / 4.0);
        writeBatchBytes = std::min(kWriteBatchBytes, limits.bytes);
        hotLimitBytes = std::min(kHotRingMaxBytes, limits.bytes);
        if (directory.empty()) {
#ifdef BRUTV_PS5
            directory = "/download0/brutv";
            std::error_code error;
            std::filesystem::create_directories(directory, error);
            if (error) {
                throw std::runtime_error("Cannot create temporary storage for live rewind.");
            }
#else
            std::error_code error;
            directory = std::filesystem::temp_directory_path(error).string();
            if (error) {
                throw std::runtime_error("Cannot locate temporary storage for live rewind.");
            }
#endif
        }
    }

    void trimHotRingBefore(std::uint64_t minSequence) {
        while (!hotRing.empty() && hotRing.front().sequence < minSequence) {
            hotBytes -= hotRing.front().data->size();
            hotRing.pop_front();
        }
    }

    void pushHotPacket(std::uint64_t sequence, std::shared_ptr<std::vector<std::uint8_t>> blob) {
        const std::size_t blobSize = blob->size();
        if (blobSize > hotLimitBytes) {
            hotRing.clear();
            hotBytes = 0;
            return;
        }
        while (!hotRing.empty() && hotBytes + blobSize > hotLimitBytes) {
            hotBytes -= hotRing.front().data->size();
            hotRing.pop_front();
        }
        hotBytes += blobSize;
        hotRing.push_back({sequence, std::move(blob)});
    }

    void discardOldest() {
        bytes -= chunks.front()->bytes;
        records -= chunks.front()->records.size();
        chunks.pop_front();
        if (chunks.empty()) {
            hotRing.clear();
            hotBytes = 0;
        } else {
            trimHotRingBefore(chunks.front()->records.front().sequence);
        }
    }
};

PacketSpool::PacketSpool() : PacketSpool(Limits{}) {}

PacketSpool::PacketSpool(Limits limits, std::string directory)
    : impl_(std::make_unique<Impl>(limits, std::move(directory))) {}

PacketSpool::~PacketSpool() = default;

bool PacketSpool::append(const AVPacket* packet, double timelineSeconds, bool videoKeyframe) {
    if (!packet || packet->size < 0 || (packet->size > 0 && !packet->data) ||
        packet->side_data_elems < 0 || packet->side_data_elems > kMaxSideData ||
        !std::isfinite(timelineSeconds) || timelineSeconds < 0.0) {
        throw std::invalid_argument("Invalid packet for the live buffer.");
    }
    std::size_t size = sizeof(PacketHeader);
    const auto addSize = [&](std::size_t amount) {
        if (amount > impl_->limits.bytes - size) {
            return false;
        }
        size += amount;
        return true;
    };
    if (!addSize(static_cast<std::size_t>(packet->size))) {
        return false;
    }
    for (int index = 0; index < packet->side_data_elems; ++index) {
        const auto& side = packet->side_data[index];
        if ((side.size > 0 && !side.data) || !addSize(sizeof(SideHeader)) || !addSize(side.size)) {
            return false;
        }
    }

    // Serialize outside the mutex to minimize lock hold time.
    auto serialized = std::make_shared<std::vector<std::uint8_t>>();
    serializePacket(packet, size, *serialized);

    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->finished) {
        return false;
    }
    timelineSeconds = std::max(timelineSeconds, impl_->endSeconds);
    impl_->endSeconds = std::max(impl_->endSeconds, timelineSeconds);
    while (!impl_->chunks.empty() &&
           (impl_->bytes > impl_->limits.bytes - size || impl_->records >= kMaxRecords ||
            impl_->endSeconds - impl_->chunks.front()->records.front().seconds >
                impl_->limits.seconds)) {
        impl_->discardOldest();
    }
    if (impl_->chunks.empty() && !videoKeyframe) {
        return true;
    }
    const bool newChunk =
        impl_->chunks.empty() ||
        (videoKeyframe &&
         (timelineSeconds - impl_->chunks.back()->records.front().seconds >= impl_->chunkSeconds ||
          impl_->chunks.back()->bytes + size > impl_->limits.bytes / 4));
    if (newChunk) {
        if (!impl_->chunks.empty()) {
            impl_->chunks.back()->seal();
        }
        while (impl_->chunks.size() >= kMaxChunks) {
            impl_->discardOldest();
        }
        auto chunk = std::make_shared<Chunk>(impl_->directory);
        chunk->writeBuf.reserve(impl_->writeBatchBytes);
        impl_->chunks.push_back(std::move(chunk));
    }
    Chunk& chunk = *impl_->chunks.back();
    const std::size_t recordOffset = chunk.bytes;
    try {
        if (serialized->size() >= impl_->writeBatchBytes) {
            chunk.flush();
            pwriteAll(chunk.fd, serialized->data(), serialized->size(), chunk.flushedBytes);
            chunk.flushedBytes += serialized->size();
        } else {
            if (chunk.writeBuf.size() + serialized->size() > impl_->writeBatchBytes) {
                chunk.flush();
            }
            chunk.writeBuf.insert(chunk.writeBuf.end(), serialized->begin(), serialized->end());
            if (chunk.writeBuf.size() >= impl_->writeBatchBytes) {
                chunk.flush();
            }
        }
    } catch (...) {
        impl_->bytes -= chunk.bytes;
        impl_->records -= chunk.records.size();
        impl_->chunks.pop_back();
        if (impl_->chunks.empty()) {
            impl_->hotRing.clear();
            impl_->hotBytes = 0;
        }
        throw;
    }

    const std::uint64_t sequence = impl_->nextSequence++;
    if (videoKeyframe) {
        chunk.keyframes.push_back(chunk.records.size());
    }
    chunk.records.push_back({sequence, recordOffset, size, timelineSeconds, videoKeyframe});
    chunk.bytes += size;
    impl_->bytes += size;
    ++impl_->records;
    impl_->pushHotPacket(sequence, std::move(serialized));
    return true;
}

PacketSpool::ReadResult PacketSpool::read(std::uint64_t& cursor, AVPacket* packet) {
    if (!packet) {
        throw std::invalid_argument("A live buffer output packet is required.");
    }

    std::shared_ptr<const std::vector<std::uint8_t>> hotBlob;
    std::vector<std::uint8_t> copiedBytes;
    std::shared_ptr<Chunk> diskChunk;
    std::size_t diskOffset = 0;
    std::size_t diskSize = 0;
    std::uint64_t nextCursor = 0;

    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        if (impl_->chunks.empty()) {
            return impl_->finished ? ReadResult::Finished : ReadResult::Waiting;
        }
        const auto first = impl_->chunks.front()->records.front().sequence;
        if (cursor == 0) {
            cursor = first;
        } else if (cursor < first) {
            cursor = first;
            return ReadResult::Expired;
        }

        // Fast path: live-edge reads served straight from the in-memory hot tail ring (0 syscalls).
        if (!impl_->hotRing.empty() && cursor >= impl_->hotRing.front().sequence &&
            cursor <= impl_->hotRing.back().sequence) {
            const std::size_t idx =
                static_cast<std::size_t>(cursor - impl_->hotRing.front().sequence);
            const auto& entry = impl_->hotRing[idx];
            if (entry.sequence == cursor) {
                hotBlob = entry.data;
                nextCursor = cursor + 1;
            }
        }

        if (!hotBlob) {
            const auto chunkIt = std::lower_bound(
                impl_->chunks.begin(), impl_->chunks.end(), cursor,
                [](const std::shared_ptr<Chunk>& candidate, std::uint64_t sequence) {
                    return candidate->records.back().sequence < sequence;
                });
            if (chunkIt == impl_->chunks.end()) {
                return impl_->finished ? ReadResult::Finished : ReadResult::Waiting;
            }
            const auto& chunk = *chunkIt;
            const auto record = std::lower_bound(
                chunk->records.begin(), chunk->records.end(), cursor,
                [](const Chunk::Record& candidate, std::uint64_t sequence) {
                    return candidate.sequence < sequence;
                });
            if (record == chunk->records.end()) {
                return impl_->finished ? ReadResult::Finished : ReadResult::Waiting;
            }
            nextCursor = record->sequence + 1;
            if (record->offset >= chunk->flushedBytes) {
                // Still resident in the active chunk's batched write buffer.
                const std::size_t bufOffset = record->offset - chunk->flushedBytes;
                if (bufOffset + record->size > chunk->writeBuf.size()) {
                    throw std::runtime_error("Live buffer write cache inconsistency.");
                }
                copiedBytes.assign(chunk->writeBuf.begin() + static_cast<std::ptrdiff_t>(bufOffset),
                                   chunk->writeBuf.begin() +
                                       static_cast<std::ptrdiff_t>(bufOffset + record->size));
            } else {
                // Flushed region on disk: hold shared_ptr to keep fd alive and pread outside mutex.
                diskChunk = chunk;
                diskOffset = record->offset;
                diskSize = record->size;
            }
        }
    }

    if (hotBlob) {
        deserializePacket(hotBlob->data(), hotBlob->size(), packet);
    } else if (!copiedBytes.empty()) {
        deserializePacket(copiedBytes.data(), copiedBytes.size(), packet);
    } else {
        std::vector<std::uint8_t> diskBuf(diskSize);
        preadAll(diskChunk->fd, diskBuf.data(), diskSize, diskOffset);
        deserializePacket(diskBuf.data(), diskBuf.size(), packet);
    }
    cursor = nextCursor;
    return ReadResult::Ready;
}

std::uint64_t PacketSpool::seek(double targetSeconds) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->chunks.empty()) {
        return 0;
    }
    const auto chunkIt = std::upper_bound(
        impl_->chunks.begin(), impl_->chunks.end(), targetSeconds,
        [](double target, const std::shared_ptr<Chunk>& candidate) {
            return target < candidate->records.front().seconds;
        });
    if (chunkIt == impl_->chunks.begin()) {
        return impl_->chunks.front()->records.front().sequence;
    }
    const auto& chunk = *std::prev(chunkIt);
    if (chunk->keyframes.empty()) {
        return chunk->records.front().sequence;
    }
    const auto keyframeIt = std::upper_bound(
        chunk->keyframes.begin(), chunk->keyframes.end(), targetSeconds,
        [&](double target, std::size_t index) {
            return target < chunk->records[index].seconds;
        });
    if (keyframeIt == chunk->keyframes.begin()) {
        return chunk->records[chunk->keyframes.front()].sequence;
    }
    return chunk->records[*std::prev(keyframeIt)].sequence;
}

PacketSpool::Snapshot PacketSpool::snapshot() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    Snapshot result;
    result.startSeconds = impl_->chunks.empty() ? impl_->endSeconds
                                                : impl_->chunks.front()->records.front().seconds;
    result.endSeconds = impl_->endSeconds;
    result.bytes = impl_->bytes;
    result.finished = impl_->finished;
    return result;
}

void PacketSpool::close() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (!impl_->chunks.empty()) {
        try {
            impl_->chunks.back()->seal();
        } catch (...) {
            // Closing spool must not throw; readers can still drain hot/flushed packets.
        }
    }
    impl_->finished = true;
}

} // namespace brutv
