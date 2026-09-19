#include "hoshidicts/query.hpp"

#include <ankerl/unordered_dense.h>
#include <zstd.h>

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <ranges>
#include <stdexcept>
#include <limits>
#include <string_view>
#include <vector>

#include "hash/hash.hpp"
#include "hoshidicts/importer.hpp"
#include "json/yomitan_parser.hpp"
#include "memory/memory.hpp"
#include "path_utils.hpp"

namespace {
// Never form an out-of-range pointer from an offset stored on disk.
const uint8_t* checked_offset(const memory::mapped_file& mapping, uint64_t offset, size_t length = 0) {
  if (!mapping.data || offset > mapping.size || length > mapping.size - size_t(offset)) {
    throw std::runtime_error("Invalid dictionary offset");
  }
  return mapping.data + size_t(offset);
}

void require_bytes(const uint8_t* addr, const uint8_t* end, size_t length) {
  if (length > size_t(end - addr)) throw std::runtime_error("Truncated dictionary record");
}

template <typename T>
T read_val(const uint8_t*& addr, const uint8_t* end) {
  require_bytes(addr, end, sizeof(T));
  T val;
  std::memcpy(&val, addr, sizeof(T));
  addr += sizeof(T);
  return val;
}

std::string_view read_str(const uint8_t*& addr, uint32_t len, const uint8_t* end) {
  require_bytes(addr, end, len);
  std::string_view result(reinterpret_cast<const char*>(addr), len);
  addr += len;
  return result;
}

void require_count(const uint8_t* addr, const uint8_t* end, uint64_t count, size_t minimum_bytes) {
  if (count > size_t(end - addr) / minimum_bytes) throw std::runtime_error("Invalid dictionary record count");
}
}

struct DictionaryQuery::DictionaryData {
  int version;
  hash::linear table;
  hash::bloom bloom;
  memory::mapped_file blobs;
  memory::mapped_file hash_table;
  memory::mapped_file bloom_filter;
  memory::mapped_file media;
  memory::mapped_file media_index;

  ~DictionaryData() {
    memory::unmap(blobs);
    memory::unmap(hash_table);
    memory::unmap(bloom_filter);
    memory::unmap(media);
    memory::unmap(media_index);
  }
};

DictionaryQuery::DictionaryQuery() = default;
DictionaryQuery::~DictionaryQuery() = default;

DictionaryQuery::DictionaryQuery(DictionaryQuery&&) noexcept = default;
DictionaryQuery& DictionaryQuery::operator=(DictionaryQuery&&) noexcept = default;

DictionaryQuery::Dictionary::Dictionary() = default;
DictionaryQuery::Dictionary::~Dictionary() = default;

DictionaryQuery::Dictionary::Dictionary(Dictionary&&) noexcept = default;
DictionaryQuery::Dictionary& DictionaryQuery::Dictionary::operator=(Dictionary&&) noexcept = default;

void DictionaryQuery::add_dict(const std::string& path_utf8, DictionaryType type) try {
  failed_ = false;
  const std::filesystem::path path = path_utils::from_utf8(path_utf8);
  int version = 0;
  if (std::filesystem::is_regular_file(path / ".hoshidicts_3")) {
    version = 3;
  } else if (std::filesystem::is_regular_file(path / ".hoshidicts_2")) {
    version = 2;
  } else if (std::filesystem::is_regular_file(path / ".hoshidicts_1")) {
    version = 1;
  } else {
    throw std::runtime_error("Dictionary could not be loaded");
  }

  Dictionary dict;
  Summary summary;
  std::ifstream index_file(path / "index.json", std::ios::binary);
  if (!index_file) {
    throw std::runtime_error("Dictionary could not be loaded");
  }
  std::string buf(std::istreambuf_iterator<char>(index_file), {});
  if (glz::read<glz::opts{.error_on_unknown_keys = false}>(summary, buf)) {
    throw std::runtime_error("Dictionary could not be loaded");
  }

  dict.name = summary.title.empty() ? path_utils::to_utf8(path.stem()) : summary.title;
  dict.styles = summary.styles;
  if (dict.styles.empty() && std::filesystem::exists(path / "styles.css")) {
    std::ifstream f(path / "styles.css");
    dict.styles = std::string(std::istreambuf_iterator<char>(f), {});
  }

  dict.data = std::make_unique<DictionaryData>();
  dict.data->version = version;

  dict.data->hash_table = memory::map_rd(path / "hash.table");
  if (!dict.data->hash_table) {
    throw std::runtime_error("Dictionary could not be loaded");
  }
  if (!dict.data->table.load(dict.data->hash_table.data, dict.data->hash_table.size)) {
    throw std::runtime_error("Dictionary could not be loaded");
  }

  dict.data->bloom_filter = memory::map_rd(path / "bloom.filter");
  if (!dict.data->bloom_filter) {
    throw std::runtime_error("Dictionary could not be loaded");
  }
  if (!dict.data->bloom.load(dict.data->bloom_filter.data, dict.data->bloom_filter.size)) {
    throw std::runtime_error("Dictionary could not be loaded");
  }
  dict.data->table.set_bloom(&dict.data->bloom);

  dict.data->blobs = memory::map_rd(path / "blobs.bin");
  if (!dict.data->blobs) {
    throw std::runtime_error("Dictionary could not be loaded");
  }

  dict.data->media = memory::map_rd(path / "media.bin");
  if (dict.data->media) {
    dict.data->media_index = memory::map_rd(path / "media.idx");
  }

  switch (type) {
    case TERM:
      term_dicts_.push_back(std::move(dict));
      break;
    case FREQ:
      freq_dicts_.push_back(std::move(dict));
      break;
    case PITCH:
      pitch_dicts_.push_back(std::move(dict));
      break;
    case KANJI:
      kanji_dicts_.push_back(std::move(dict));
      break;
  }
} catch (...) {
  failed_ = true;
}

void DictionaryQuery::add_term_dict(const std::string& path) { add_dict(path, DictionaryQuery::DictionaryType::TERM); }

void DictionaryQuery::add_freq_dict(const std::string& path) { add_dict(path, DictionaryQuery::DictionaryType::FREQ); }

void DictionaryQuery::add_pitch_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::PITCH);
}

void DictionaryQuery::add_kanji_dict(const std::string& path) {
  add_dict(path, DictionaryQuery::DictionaryType::KANJI);
}

std::vector<TermResult> DictionaryQuery::query(const std::string& expression) const try {
  failed_ = false;
  auto results = query_raw(expression);
  for (auto& term : results) {
    materialize(term);
  }
  return results;
} catch (...) {
  failed_ = true;
  return {};
}

std::vector<TermResult> DictionaryQuery::query_raw(const std::string& expression) const {
  std::map<std::pair<std::string_view, std::string_view>, TermResult> term_map;
  for (const auto& [name, styles, data] : term_dicts_) {
    uint64_t offset_addr = data->table(expression);
    if (offset_addr == 0) {
      continue;
    }
    const uint8_t* blob_end = data->blobs.data + data->blobs.size;
    const uint8_t* index_addr = checked_offset(data->blobs, offset_addr);

    auto count = read_val<uint32_t>(index_addr, blob_end);
    require_count(index_addr, blob_end, count, sizeof(uint64_t));
    for (uint32_t i = 0; i < count; i++) {
      auto offset = read_val<uint64_t>(index_addr, blob_end);
      const uint8_t* blob_addr = checked_offset(data->blobs, offset);

      // first byte encodes term (0) or meta (1) entry
      auto type = read_val<uint8_t>(blob_addr, blob_end);
      if (type != 0) {
        continue;
      }

      auto expr_len = read_val<uint16_t>(blob_addr, blob_end);
      std::string_view expr = read_str(blob_addr, expr_len, blob_end);

      auto reading_len = read_val<uint16_t>(blob_addr, blob_end);
      std::string_view reading = read_str(blob_addr, reading_len, blob_end);

      if (expr != expression && reading != expression) {
        continue;
      }

      auto glossary_offset = read_val<uint64_t>(blob_addr, blob_end);
      auto glossary_size = read_val<uint32_t>(blob_addr, blob_end);

      auto def_tags_size = read_val<uint8_t>(blob_addr, blob_end);
      std::string_view definition_tags = read_str(blob_addr, def_tags_size, blob_end);

      auto rules_size = read_val<uint8_t>(blob_addr, blob_end);
      std::string_view rules = read_str(blob_addr, rules_size, blob_end);

      auto term_tag_size = read_val<uint8_t>(blob_addr, blob_end);
      std::string_view term_tags = read_str(blob_addr, term_tag_size, blob_end);

      if (data->version >= 2) {
        auto redirect_count = read_val<uint32_t>(blob_addr, blob_end);
        require_count(blob_addr, blob_end, redirect_count, 2 * sizeof(uint32_t));
        for (uint32_t r = 0; r < redirect_count; r++) {
          auto form_of_len = read_val<uint32_t>(blob_addr, blob_end);
          read_str(blob_addr, form_of_len, blob_end);
          auto rule_count = read_val<uint32_t>(blob_addr, blob_end);
          require_count(blob_addr, blob_end, rule_count, sizeof(uint32_t));
          for (uint32_t j = 0; j < rule_count; j++) {
            auto rule_len = read_val<uint32_t>(blob_addr, blob_end);
            read_str(blob_addr, rule_len, blob_end);
          }
        }
      }

      int score = 0;
      if (data->version >= 3) {
        score = read_val<int32_t>(blob_addr, blob_end);
      }

      GlossaryEntry entry;
      entry.dict_name = name;
      entry.definition_tags = definition_tags;
      entry.term_tags = term_tags;
      entry.compressed_data = checked_offset(data->blobs, glossary_offset, glossary_size);
      entry.compressed_size = glossary_size;

      auto [it, inserted] = term_map.try_emplace({expr, reading});
      if (inserted) {
        it->second = {.expression = std::string(expr),
                      .reading = std::string(reading),
                      .rules = std::string(rules),
                      .score = score,
                      .glossaries = {},
                      .frequencies = {}};
      } else {
        if (!rules.empty()) {
          if (!it->second.rules.empty()) {
            it->second.rules += " ";
          }
          it->second.rules += rules;
        }
        it->second.score = std::max(it->second.score, score);
      }
      it->second.glossaries.push_back(std::move(entry));
    }
  }

  auto results = term_map | std::views::values | std::views::as_rvalue | std::ranges::to<std::vector>();
  query_freq_raw(results);
  query_pitch_raw(results);

  return results;
}

void DictionaryQuery::query_freq(std::vector<TermResult>& terms) const try {
  failed_ = false;
  auto updated = terms;
  query_freq_raw(updated);
  terms = std::move(updated);
} catch (...) {
  failed_ = true;
}

void DictionaryQuery::query_freq_raw(std::vector<TermResult>& terms) const {
  for (auto& term : terms) {
    for (const auto& [name, styles, data] : freq_dicts_) {
      uint64_t offset_addr = data->table(term.expression);
      if (offset_addr == 0) {
        continue;
      }
      const uint8_t* blob_end = data->blobs.data + data->blobs.size;
    const uint8_t* index_addr = checked_offset(data->blobs, offset_addr);
      auto count = read_val<uint32_t>(index_addr, blob_end);
    require_count(index_addr, blob_end, count, sizeof(uint64_t));

      std::vector<Frequency> frequencies;
      for (uint32_t i = 0; i < count; i++) {
        auto offset = read_val<uint64_t>(index_addr, blob_end);
        const uint8_t* blob_addr = checked_offset(data->blobs, offset);

        auto type = read_val<uint8_t>(blob_addr, blob_end);
        if (type != 1) {
          continue;
        }

        auto expr_len = read_val<uint16_t>(blob_addr, blob_end);
        std::string_view expr = read_str(blob_addr, expr_len, blob_end);
        if (expr != term.expression) {
          continue;
        }

        auto mode_len = read_val<uint8_t>(blob_addr, blob_end);
        std::string_view mode = read_str(blob_addr, mode_len, blob_end);
        if (mode != "freq") {
          continue;
        }

        auto freq_data_size = read_val<uint32_t>(blob_addr, blob_end);
        std::string_view freq_data = read_str(blob_addr, freq_data_size, blob_end);

        ParsedFrequency parsed;
        if (!yomitan_parser::parse_frequency(freq_data, parsed)) throw std::runtime_error("Invalid frequency data");
        {
          if (!parsed.reading.empty() && parsed.reading != term.reading) {
            continue;
          }
          frequencies.emplace_back(
              Frequency{.value = parsed.value, .display_value = std::string(parsed.display_value)});
        }
      }
      if (!frequencies.empty()) {
        term.frequencies.emplace_back(FrequencyEntry{.dict_name = name, .frequencies = std::move(frequencies)});
      }
    }
  }
}

void DictionaryQuery::query_pitch(std::vector<TermResult>& terms) const try {
  failed_ = false;
  auto updated = terms;
  query_pitch_raw(updated);
  terms = std::move(updated);
} catch (...) {
  failed_ = true;
}

void DictionaryQuery::query_pitch_raw(std::vector<TermResult>& terms) const {
  for (auto& term : terms) {
    for (const auto& [name, styles, data] : pitch_dicts_) {
      uint64_t offset_addr = data->table(term.expression);
      if (offset_addr == 0) {
        continue;
      }
      const uint8_t* blob_end = data->blobs.data + data->blobs.size;
    const uint8_t* index_addr = checked_offset(data->blobs, offset_addr);
      auto count = read_val<uint32_t>(index_addr, blob_end);
    require_count(index_addr, blob_end, count, sizeof(uint64_t));

      std::vector<Pitch> pitches;
      std::vector<std::string> transcriptions;
      for (uint32_t i = 0; i < count; i++) {
        auto offset = read_val<uint64_t>(index_addr, blob_end);
        const uint8_t* blob_addr = checked_offset(data->blobs, offset);

        auto type = read_val<uint8_t>(blob_addr, blob_end);
        if (type != 1) {
          continue;
        }

        auto expr_len = read_val<uint16_t>(blob_addr, blob_end);
        std::string_view expr = read_str(blob_addr, expr_len, blob_end);
        if (expr != term.expression) {
          continue;
        }

        auto mode_len = read_val<uint8_t>(blob_addr, blob_end);
        std::string_view mode = read_str(blob_addr, mode_len, blob_end);
        ParsedPitch parsed;
        if (mode == "pitch") {
          auto pitch_data_size = read_val<uint32_t>(blob_addr, blob_end);
          std::string_view pitch_data = read_str(blob_addr, pitch_data_size, blob_end);

          if (!yomitan_parser::parse_pitch(pitch_data, parsed)) throw std::runtime_error("Invalid pitch data");
          {
            if (!parsed.reading.empty() && parsed.reading != term.reading) {
              continue;
            }
            for (auto& accent : parsed.pitches) {
              pitches.emplace_back(Pitch{.position = accent.position,
                                         .pattern = std::move(accent.pattern),
                                         .nasal = std::move(accent.nasal),
                                         .devoice = std::move(accent.devoice)});
            }
          }
        } else if (mode == "ipa") {
          auto transcriptions_data_size = read_val<uint32_t>(blob_addr, blob_end);
          std::string_view transcriptions_data = read_str(blob_addr, transcriptions_data_size, blob_end);
          if (!yomitan_parser::parse_ipa(transcriptions_data, parsed)) throw std::runtime_error("Invalid IPA data");
          {
            if (!parsed.reading.empty() && parsed.reading != term.reading) {
              continue;
            }
            for (std::string_view transcription : parsed.transcriptions) {
              transcriptions.emplace_back(transcription);
            }
          }
        }
      }
      if (!pitches.empty() || !transcriptions.empty()) {
        term.pitches.emplace_back(PitchEntry{
            .dict_name = name,
            .pitches = std::move(pitches),
            .transcriptions = std::move(transcriptions),
        });
      }
    }
  }
}

KanjiResult DictionaryQuery::query_kanji(const std::string& kanji) const try {
  failed_ = false;
  KanjiResult result;
  result.character = kanji;

  for (const auto& [name, styles, data] : kanji_dicts_) {
    uint64_t offset_addr = data->table(kanji);
    if (offset_addr == 0) {
      continue;
    }
    const uint8_t* blob_end = data->blobs.data + data->blobs.size;
    const uint8_t* index_addr = checked_offset(data->blobs, offset_addr);
    auto count = read_val<uint32_t>(index_addr, blob_end);
    require_count(index_addr, blob_end, count, sizeof(uint64_t));

    for (uint32_t i = 0; i < count; i++) {
      auto offset = read_val<uint64_t>(index_addr, blob_end);
      const uint8_t* blob_addr = checked_offset(data->blobs, offset);

      auto type = read_val<uint8_t>(blob_addr, blob_end);
      if (type != 2) {
        continue;
      }

      auto char_len = read_val<uint8_t>(blob_addr, blob_end);
      std::string_view char_sv = read_str(blob_addr, char_len, blob_end);
      if (char_sv != kanji) {
        continue;
      }

      auto onyomi_len = read_val<uint16_t>(blob_addr, blob_end);
      std::string_view onyomi = read_str(blob_addr, onyomi_len, blob_end);

      auto kunyomi_len = read_val<uint16_t>(blob_addr, blob_end);
      std::string_view kunyomi = read_str(blob_addr, kunyomi_len, blob_end);

      auto tags_len = read_val<uint16_t>(blob_addr, blob_end);
      std::string_view tags = read_str(blob_addr, tags_len, blob_end);

      KanjiEntry entry;
      entry.dict_name = name;
      entry.onyomi = onyomi;
      entry.kunyomi = kunyomi;
      entry.tags = tags;

      auto def_count = read_val<uint16_t>(blob_addr, blob_end);
      require_count(blob_addr, blob_end, def_count, sizeof(uint16_t));
      for (uint16_t j = 0; j < def_count; j++) {
        auto def_len = read_val<uint16_t>(blob_addr, blob_end);
        std::string_view def = read_str(blob_addr, def_len, blob_end);
        entry.definitions.emplace_back(def);
      }

      auto stat_count = read_val<uint16_t>(blob_addr, blob_end);
      require_count(blob_addr, blob_end, stat_count, 2 * sizeof(uint16_t));
      for (uint16_t j = 0; j < stat_count; j++) {
        auto key_len = read_val<uint16_t>(blob_addr, blob_end);
        std::string_view key = read_str(blob_addr, key_len, blob_end);
        auto val_len = read_val<uint16_t>(blob_addr, blob_end);
        std::string_view val = read_str(blob_addr, val_len, blob_end);
        entry.stats.emplace(key, val);
      }

      result.entries.push_back(std::move(entry));
    }
  }

  return result;
} catch (...) {
  failed_ = true;
  return {};
}

std::string DictionaryQuery::decompress_glossary(const void* data, size_t size) {
  if (!data || size == 0) {
    throw std::runtime_error("Empty dictionary glossary");
  }

  unsigned long long decompressed_size = ZSTD_getFrameContentSize(data, size);
  if (decompressed_size == ZSTD_CONTENTSIZE_ERROR || decompressed_size == ZSTD_CONTENTSIZE_UNKNOWN ||
      decompressed_size > 64ULL * 1024 * 1024) {
    throw std::runtime_error("Invalid or oversized dictionary glossary");
  }

  std::string result;
  result.resize(decompressed_size);

  size_t actual_size = ZSTD_decompress(result.data(), result.size(), data, size);
  if (ZSTD_isError(actual_size) || actual_size != decompressed_size) {
    throw std::runtime_error("Could not decompress dictionary glossary");
  }

  result.resize(actual_size);
  return result;
}

void DictionaryQuery::materialize(TermResult& term) const {
  for (auto& g : term.glossaries) {
    g.glossary = decompress_glossary(g.compressed_data, g.compressed_size);
  }
}

std::vector<char> DictionaryQuery::get_media_file(const std::string& dict_name, const std::string& media_path) const try {
  failed_ = false;
  auto view = get_media_file_view(dict_name, media_path);
  if (!view.data || !view.size) return {};
  return {view.data, view.data + view.size};
} catch (...) {
  failed_ = true;
  return {};
}

MediaFileView DictionaryQuery::get_media_file_view(const std::string& dict_name, const std::string& media_path) const try {
  failed_ = false;
  for (const auto& [name, styles, data] : term_dicts_) {
    if (name != dict_name) {
      continue;
    }

    if (!data->media || !data->media_index) {
      return {};
    }

    const uint8_t* ptr = data->media_index.data;
    const uint8_t* index_end = ptr + data->media_index.size;
    const uint8_t* media_end = data->media.data + data->media.size;
    auto count = read_val<uint32_t>(ptr, index_end);
    require_count(ptr, index_end, count, sizeof(uint64_t));

    size_t left = 0;
    size_t right = count;
    while (left < right) {
      const size_t mid = left + (right - left) / 2;
      uint64_t record_offset;
      std::memcpy(&record_offset, data->media_index.data + sizeof(uint32_t) + mid * sizeof(uint64_t), sizeof(uint64_t));

      const uint8_t* record = checked_offset(data->media, record_offset);
      auto path_size = read_val<uint16_t>(record, media_end);
      std::string_view indexed_path = read_str(record, path_size, media_end);
      if (indexed_path < media_path) {
        left = mid + 1;
      } else if (indexed_path > media_path) {
        right = mid;
      } else {
        auto blob_size = read_val<uint32_t>(record, media_end);
        require_bytes(record, media_end, blob_size);
        const char* blob_data = reinterpret_cast<const char*>(record);
        return {.data = blob_data, .size = blob_size};
      }
    }
    return {};
  }
  return {};
} catch (...) {
  failed_ = true;
  return {};
}

std::vector<DictionaryStyle> DictionaryQuery::get_styles() const try {
  failed_ = false;
  return term_dicts_ | std::views::filter([](const auto& d) { return !d.styles.empty(); }) |
         std::views::transform([](const auto& d) { return DictionaryStyle{d.name, d.styles}; }) |
         std::ranges::to<std::vector>();
} catch (...) {
  failed_ = true;
  return {};
}

std::vector<std::string> DictionaryQuery::get_freq_dict_order() const try {
  failed_ = false;
  return freq_dicts_ | std::views::transform([](const auto& d) { return d.name; }) | std::ranges::to<std::vector>();
} catch (...) {
  failed_ = true;
  return {};
}
