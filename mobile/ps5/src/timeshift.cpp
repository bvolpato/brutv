#include "brutv/timeshift.hpp"

extern "C" {
#include <libavcodec/packet.h>
}

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <deque>
#include <filesystem>
#include <limits>
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

bool transfer(int fd, void* data, std::size_t bytes, bool writing) {
    auto* position = static_cast<char*>(data);
    while (bytes > 0) {
        const auto count = writing ? ::write(fd, position, bytes) : ::read(fd, position, bytes);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            return false;
        }
        position += count;
        bytes -= static_cast<std::size_t>(count);
    }
    return true;
}

void writeBytes(int fd, const void* data, std::size_t bytes) {
    if (!transfer(fd, const_cast<void*>(data), bytes, true)) {
        throw std::runtime_error("Cannot write the temporary live buffer.");
    }
}

void readBytes(int fd, void* data, std::size_t bytes) {
    if (!transfer(fd, data, bytes, false)) {
        throw std::runtime_error("Cannot read the temporary live buffer.");
    }
}

struct Chunk {
    struct Record {
        std::uint64_t sequence = 0;
        std::size_t offset = 0;
        double seconds = 0.0;
        bool keyframe = false;
    };
    int fd = -1;
    std::size_t bytes = 0;
    std::vector<Record> records;

    explicit Chunk(const std::string& directory) {
        std::string pattern = directory + "/brutv-rewind-XXXXXX";
        std::vector<char> name(pattern.begin(), pattern.end());
        name.push_back('\0');
        fd = ::mkstemp(name.data());
        if (fd < 0) {
            throw std::runtime_error("Cannot create temporary storage for live rewind.");
        }
        const bool privateFile = ::fchmod(fd, S_IRUSR | S_IWUSR) == 0;
        const bool unlinked = ::unlink(name.data()) == 0;
        if (!privateFile || !unlinked) {
            ::close(fd);
            fd = -1;
            (void)::unlink(name.data());
            throw std::runtime_error("Cannot secure temporary storage for live rewind.");
        }
    }
    ~Chunk() {
        if (fd >= 0) {
            ::close(fd);
        }
    }
};

} // namespace

struct PacketSpool::Impl {
    Limits limits;
    std::string directory;
    double chunkSeconds = 8.0;
    mutable std::mutex mutex;
    std::deque<std::unique_ptr<Chunk>> chunks;
    std::size_t bytes = 0;
    std::size_t records = 0;
    std::uint64_t nextSequence = 1;
    double endSeconds = 0.0;
    bool finished = false;

    Impl(Limits requested, std::string temporary) : limits(requested), directory(std::move(temporary)) {
        if (!std::isfinite(limits.seconds) || limits.seconds <= 0.0 ||
            limits.bytes < sizeof(PacketHeader) + 1 ||
            limits.bytes > static_cast<std::size_t>(std::numeric_limits<off_t>::max())) {
            throw std::invalid_argument("Invalid live buffer limits.");
        }
        chunkSeconds = std::min(8.0, limits.seconds / 4.0);
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

    void discardOldest() {
        bytes -= chunks.front()->bytes;
        records -= chunks.front()->records.size();
        chunks.pop_front();
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
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->finished) {
        return false;
    }
    timelineSeconds = std::max(timelineSeconds, impl_->endSeconds);
    impl_->endSeconds = std::max(impl_->endSeconds, timelineSeconds);
    while (!impl_->chunks.empty() &&
           (impl_->bytes > impl_->limits.bytes - size || impl_->records >= kMaxRecords ||
            impl_->endSeconds - impl_->chunks.front()->records.front().seconds > impl_->limits.seconds)) {
        impl_->discardOldest();
    }
    if (impl_->chunks.empty() && !videoKeyframe) {
        return true;
    }
    const bool newChunk = impl_->chunks.empty() || (videoKeyframe &&
        (timelineSeconds - impl_->chunks.back()->records.front().seconds >= impl_->chunkSeconds ||
         impl_->chunks.back()->bytes + size > impl_->limits.bytes / 4));
    if (newChunk) {
        while (impl_->chunks.size() >= kMaxChunks) {
            impl_->discardOldest();
        }
        auto chunk = std::make_unique<Chunk>(impl_->directory);
        chunk->records.reserve(128);
        impl_->chunks.push_back(std::move(chunk));
    }
    Chunk& chunk = *impl_->chunks.back();
    if (chunk.records.size() == chunk.records.capacity()) {
        chunk.records.reserve(std::min(kMaxRecords, chunk.records.size() + 128));
    }
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
    if (::lseek(chunk.fd, static_cast<off_t>(chunk.bytes), SEEK_SET) < 0) {
        throw std::runtime_error("Cannot position the temporary live buffer.");
    }
    try {
        writeBytes(chunk.fd, &header, sizeof(header));
        writeBytes(chunk.fd, packet->data, static_cast<std::size_t>(packet->size));
        for (int index = 0; index < packet->side_data_elems; ++index) {
            const auto& side = packet->side_data[index];
            SideHeader sideHeader{};
            sideHeader.size = side.size;
            sideHeader.type = side.type;
            writeBytes(chunk.fd, &sideHeader, sizeof(sideHeader));
            writeBytes(chunk.fd, side.data, side.size);
        }
    } catch (...) {
        impl_->bytes -= chunk.bytes;
        impl_->records -= chunk.records.size();
        impl_->chunks.pop_back();
        throw;
    }
    chunk.records.push_back({impl_->nextSequence++, chunk.bytes, timelineSeconds, videoKeyframe});
    chunk.bytes += size;
    impl_->bytes += size;
    ++impl_->records;
    return true;
}

PacketSpool::ReadResult PacketSpool::read(std::uint64_t& cursor, AVPacket* packet) {
    if (!packet) {
        throw std::invalid_argument("A live buffer output packet is required.");
    }
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
    for (const auto& chunk : impl_->chunks) {
        const auto record = std::lower_bound(chunk->records.begin(), chunk->records.end(), cursor,
            [](const Chunk::Record& candidate, std::uint64_t sequence) { return candidate.sequence < sequence; });
        if (record == chunk->records.end()) {
            continue;
        }
        if (::lseek(chunk->fd, static_cast<off_t>(record->offset), SEEK_SET) < 0) {
            throw std::runtime_error("Cannot position the temporary live buffer.");
        }
        PacketHeader header{};
        readBytes(chunk->fd, &header, sizeof(header));
        av_packet_unref(packet);
        if (av_new_packet(packet, header.size) < 0) {
            throw std::runtime_error("Cannot allocate a live buffer packet.");
        }
        try {
            readBytes(chunk->fd, packet->data, static_cast<std::size_t>(header.size));
            packet->pts = header.pts;
            packet->dts = header.dts;
            packet->duration = header.duration;
            packet->pos = header.pos;
            packet->stream_index = header.stream;
            packet->flags = header.flags;
            packet->time_base = {header.timeBaseNum, header.timeBaseDen};
            for (int index = 0; index < header.sideCount; ++index) {
                SideHeader side{};
                readBytes(chunk->fd, &side, sizeof(side));
                auto* bytes = av_packet_new_side_data(packet,
                    static_cast<AVPacketSideDataType>(side.type), static_cast<std::size_t>(side.size));
                if (!bytes) {
                    throw std::runtime_error("Cannot allocate live buffer packet metadata.");
                }
                readBytes(chunk->fd, bytes, static_cast<std::size_t>(side.size));
            }
        } catch (...) {
            av_packet_unref(packet);
            throw;
        }
        cursor = record->sequence + 1;
        return ReadResult::Ready;
    }
    return impl_->finished ? ReadResult::Finished : ReadResult::Waiting;
}

std::uint64_t PacketSpool::seek(double targetSeconds) const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->chunks.empty()) {
        return 0;
    }
    auto sequence = impl_->chunks.front()->records.front().sequence;
    for (const auto& chunk : impl_->chunks) {
        for (const auto& record : chunk->records) {
            if (record.keyframe && record.seconds <= targetSeconds) {
                sequence = record.sequence;
            }
        }
    }
    return sequence;
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
    impl_->finished = true;
}

} // namespace brutv
