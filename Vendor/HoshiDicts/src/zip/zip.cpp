#include "zip.hpp"

#include <libdeflate.h>

#include <cstdint>
#include <cstring>
#include <memory>
#include <limits>
#include <stdexcept>

#include "../memory/memory.hpp"

namespace {
template <typename T>
T read_at(const uint8_t* base, size_t offset) {
  T val;
  std::memcpy(&val, base + offset, sizeof(T));
  return val;
}

template <typename Buffer>
Buffer decode_entry(const ZipEntry& entry, const uint8_t* source) {
  Buffer result;
  if (entry.compression_method == 0) {
    result.resize(entry.uncompressed_size);
    if (!result.empty()) std::memcpy(result.data(), source, result.size());
  } else if (entry.compression_method == 8) {
    thread_local std::unique_ptr<libdeflate_decompressor, decltype(&libdeflate_free_decompressor)> decompressor(
        libdeflate_alloc_decompressor(), &libdeflate_free_decompressor);
    if (!decompressor) throw std::bad_alloc();
    // ZIP lengths are untrusted: a tiny corrupt stream must not cause a 4 GiB
    // allocation before decoding. Grow only when real output fills the buffer.
    size_t capacity = std::min<size_t>(entry.uncompressed_size, 64 * 1024);
    for (;;) {
      result.resize(capacity);
      size_t actual = 0;
      const auto status = libdeflate_deflate_decompress(decompressor.get(), source, entry.compressed_size,
                                                       result.data(), result.size(), &actual);
      if (status == LIBDEFLATE_SUCCESS) {
        if (actual != entry.uncompressed_size) throw std::runtime_error("ZIP entry length mismatch");
        break;
      }
      if (status != LIBDEFLATE_INSUFFICIENT_SPACE || capacity == entry.uncompressed_size)
        throw std::runtime_error("invalid compressed ZIP entry");
      capacity = std::min<size_t>(entry.uncompressed_size, std::max<size_t>(capacity * 2, 1));
    }
  } else {
    throw std::runtime_error("unsupported ZIP compression");
  }
  if (libdeflate_crc32(0, result.data(), result.size()) != entry.crc32)
    throw std::runtime_error("ZIP entry checksum mismatch");
  return result;
}

}

Zip::~Zip() { memory::unmap(file); }

bool Zip::open(const std::filesystem::path& path) {
  memory::unmap(file);
  file = {};
  entries.clear();
  file = memory::map_rd(path);
  if (!file) {
    return false;
  }

  if (parse_central_directory()) return true;
  entries.clear();
  memory::unmap(file);
  file = {};
  return false;
}

int Zip::find(const std::string& name) const {
  for (int i = 0; i < static_cast<int>(entries.size()); ++i) {
    if (entries[i].name == name) {
      return i;
    }
  }
  return -1;
}

std::string Zip::read(int index) const {
  if (index < 0 || static_cast<size_t>(index) >= entries.size()) throw std::out_of_range("invalid zip entry");
  const auto& entry = entries[index];
  return decode_entry<std::string>(entry, file.data + entry.data_offset);
}

std::optional<Zip::MediaResult> Zip::read_media(int index) const {
  if (index < 0 || static_cast<size_t>(index) >= entries.size()) throw std::out_of_range("invalid zip entry");
  const auto& entry = entries[index];
  try {
    return MediaResult{entry.name, decode_entry<std::vector<char>>(entry, file.data + entry.data_offset)};
  } catch (const std::runtime_error&) {
    return std::nullopt;
  }
}

// https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT
bool Zip::parse_central_directory() {
  const auto* base = file.data;
  const auto fits = [this](uint64_t offset, uint64_t length) {
    return offset <= file.size && length <= file.size - offset;
  };
  if (file.size < 22) return false;
  size_t eocd = file.size - 22;
  const size_t earliest = file.size > 22 + 65535 ? file.size - 22 - 65535 : 0;
  for (;;) {
    if (read_at<uint32_t>(base, eocd) == 0x06054b50 &&
        read_at<uint16_t>(base, eocd + 20) == file.size - eocd - 22) break;
    if (eocd == earliest) return false;
    --eocd;
  }
  if (read_at<uint16_t>(base, eocd + 4) != 0 || read_at<uint16_t>(base, eocd + 6) != 0) return false;
  uint64_t total_entries = read_at<uint16_t>(base, eocd + 10);
  uint64_t cd_offset = read_at<uint32_t>(base, eocd + 16);
  uint64_t cd_size = read_at<uint32_t>(base, eocd + 12);
  if (eocd >= 20 && read_at<uint32_t>(base, eocd - 20) == 0x07064b50) {
    const auto eocd64 = read_at<uint64_t>(base, eocd - 12);
    if (!fits(eocd64, 56) || read_at<uint32_t>(base, eocd64) != 0x06064b50 ||
        read_at<uint32_t>(base, eocd64 + 16) != 0 || read_at<uint32_t>(base, eocd64 + 20) != 0) return false;
    total_entries = read_at<uint64_t>(base, eocd64 + 32);
    cd_size = read_at<uint64_t>(base, eocd64 + 40);
    cd_offset = read_at<uint64_t>(base, eocd64 + 48);
  }
  if (!fits(cd_offset, cd_size) || cd_offset + cd_size > eocd ||
      total_entries > cd_size / 46 || total_entries > std::numeric_limits<int>::max()) return false;
  entries.reserve(static_cast<size_t>(total_entries));
  size_t pos = static_cast<size_t>(cd_offset);
  const size_t cd_end = pos + static_cast<size_t>(cd_size);
  for (uint64_t i = 0; i < total_entries; ++i) {
    if (pos > cd_end || cd_end - pos < 46 || read_at<uint32_t>(base, pos) != 0x02014b50) return false;
    const auto flags = read_at<uint16_t>(base, pos + 8);
    if (flags & 1) return false; // encrypted entries are unsupported
    ZipEntry e{};
    e.compression_method = read_at<uint16_t>(base, pos + 10);
    e.crc32 = read_at<uint32_t>(base, pos + 16);
    uint64_t compressed = read_at<uint32_t>(base, pos + 20);
    uint64_t uncompressed = read_at<uint32_t>(base, pos + 24);
    uint64_t local = read_at<uint32_t>(base, pos + 42);
    const auto name_len = read_at<uint16_t>(base, pos + 28);
    const auto extra_len = read_at<uint16_t>(base, pos + 30);
    const auto comment_len = read_at<uint16_t>(base, pos + 32);
    const size_t record_size = 46 + size_t(name_len) + extra_len + comment_len;
    if (record_size > cd_end - pos) return false;
    e.name.assign(reinterpret_cast<const char*>(base + pos + 46), name_len);
    size_t extra = pos + 46 + name_len;
    const size_t extra_end = extra + extra_len;
    bool saw_zip64 = false;
    while (extra_end - extra >= 4) {
      const auto kind = read_at<uint16_t>(base, extra);
      const auto length = read_at<uint16_t>(base, extra + 2);
      extra += 4;
      if (length > extra_end - extra) return false;
      if (kind == 1) {
        saw_zip64 = true;
        size_t cursor = extra;
        const size_t end = extra + length;
        for (auto* field : {&uncompressed, &compressed, &local}) {
          if (*field == UINT32_MAX) {
            if (end - cursor < 8) return false;
            *field = read_at<uint64_t>(base, cursor);
            cursor += 8;
          }
        }
      }
      extra += length;
    }
    if (extra != extra_end || (!saw_zip64 && (compressed == UINT32_MAX || uncompressed == UINT32_MAX || local == UINT32_MAX)) ||
        compressed > UINT32_MAX || uncompressed > UINT32_MAX || !fits(local, 30) ||
        read_at<uint32_t>(base, local) != 0x04034b50) return false;
    if (read_at<uint16_t>(base, local + 8) != e.compression_method ||
        (read_at<uint16_t>(base, local + 6) & 1)) return false;
    const auto local_name = read_at<uint16_t>(base, local + 26);
    const auto local_extra = read_at<uint16_t>(base, local + 28);
    const uint64_t header_size = 30 + uint64_t(local_name) + local_extra;
    if (!fits(local, header_size) || !fits(local + header_size, compressed)) return false;
    if (e.compression_method == 0 && compressed != uncompressed) return false;
    if (e.compression_method != 0 && e.compression_method != 8) return false;
    e.compressed_size = static_cast<uint32_t>(compressed);
    e.uncompressed_size = static_cast<uint32_t>(uncompressed);
    e.data_offset = static_cast<size_t>(local + header_size);
    entries.push_back(std::move(e));
    pos += record_size;
  }
  return true;
}
