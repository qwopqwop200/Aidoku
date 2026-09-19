#include "yomitan_parser.hpp"

#include <string_view>
#include <algorithm>
#include <variant>

template <>
struct glz::meta<Index> {
  using T = Index;
  static constexpr bool requires_key(std::string_view key, bool) {
    return key == "title" || key == "revision";
  }
  static constexpr auto value =
      object("title", &T::title, "format", &T::format, "version", &T::version,
             "revision", &T::revision, "minimumYomitanVersion", &T::minimumYomitanVersion,
             "sequenced", &T::sequenced, "isUpdatable", &T::isUpdatable, "indexUrl", &T::indexUrl,
             "downloadUrl", &T::downloadUrl, "author", &T::author,
             "url", &T::url, "description", &T::description,
             "attribution", &T::attribution, "sourceLanguage", &T::sourceLanguage,
             "targetLanguage", &T::targetLanguage, "frequencyMode", &T::frequencyMode);
};

template <>
struct glz::meta<Term> {
  using T = Term;
  static constexpr auto value =
      array(&T::expression, &T::reading, &T::definition_tags,
            &T::rules, &T::score, &T::glossary, &T::sequence, &T::term_tags);
};

template <>
struct glz::meta<Meta> {
  using T = Meta;
  static constexpr auto value = array(&T::expression, &T::mode, &T::data);
};

template <>
struct glz::meta<Kanji> {
  using T = Kanji;
  static constexpr auto value = array(&T::character, &T::onyomi,
                                      &T::kunyomi, &T::tags, &T::definitions, &T::stats);
};

template <>
struct glz::meta<Tag> {
  using T = Tag;
  static constexpr auto value =
      array(&T::name, &T::category, &T::order, &T::notes, &T::score);
};

namespace internal {
struct FrequencyValue {
  int value;
  std::optional<std::string> display_value;
};

struct RawFrequencyFlat {
  std::optional<std::string> reading;
  int value;
  std::optional<std::string> display_value;
};

struct RawFrequency {
  std::optional<std::string> reading;
  std::variant<int, FrequencyValue> frequency;
};

struct PitchesArray {
  std::variant<int, std::string> position;
  std::optional<std::variant<int, std::vector<int>>> nasal;
  std::optional<std::variant<int, std::vector<int>>> devoice;
};

struct RawPitch {
  std::string reading;
  std::vector<PitchesArray> pitches;
};

struct TranscriptionsArray {
  std::string ipa;
};

struct RawIPA {
  std::string reading;
  std::vector<TranscriptionsArray> transcriptions;
};
};

template <>
struct glz::meta<internal::RawFrequencyFlat> {
  using T = internal::RawFrequencyFlat;
  static constexpr auto value = object("reading", &T::reading, "value", &T::value, "displayValue", &T::display_value);
};

template <>
struct glz::meta<internal::FrequencyValue> {
  using T = internal::FrequencyValue;
  static constexpr auto value = object("value", &T::value, "displayValue", &T::display_value);
};

template <>
struct glz::meta<internal::RawFrequency> {
  using T = internal::RawFrequency;
  static constexpr auto value = object("reading", &T::reading, "frequency", &T::frequency);
};

template <>
struct glz::meta<internal::PitchesArray> {
  using T = internal::PitchesArray;
  static constexpr auto value = object("position", &T::position, "nasal", &T::nasal, "devoice", &T::devoice);
};

template <>
struct glz::meta<internal::RawPitch> {
  using T = internal::RawPitch;
  static constexpr auto value = object("reading", &T::reading, "pitches", &T::pitches);
};

template <>
struct glz::meta<internal::TranscriptionsArray> {
  using T = internal::TranscriptionsArray;
  static constexpr auto value = object("ipa", &T::ipa);
};

template <>
struct glz::meta<internal::RawIPA> {
  using T = internal::RawIPA;
  static constexpr auto value = object("reading", &T::reading, "transcriptions", &T::transcriptions);
};

namespace {
// All parser inputs may be bounded slices of an mmap; never assume a trailing NUL.
struct ParseOptions : glz::opts {
  bool validate_trailing_whitespace = true;
  bool validate_skipped = true;
  bool error_on_missing_array_elements = true;
};
constexpr ParseOptions parse_options{glz::opts{
    .null_terminated = false, .error_on_unknown_keys = false, .error_on_missing_keys = true}};

}

bool yomitan_parser::parse_index(std::string_view content, Index& out) {
  auto error = glz::read<parse_options>(out, content);
  return !error && !out.title.empty();
}

bool yomitan_parser::parse_term_bank(std::string_view content, std::vector<Term>& out) {
  auto error = glz::read<parse_options>(out, content);
  return !error && std::ranges::all_of(out, [](const auto& entry) { return !entry.expression.empty(); });
}

bool yomitan_parser::parse_meta_bank(std::string_view content, std::vector<Meta>& out) {
  auto error = glz::read<parse_options>(out, content);
  return !error && std::ranges::all_of(out, [](const auto& entry) { return !entry.expression.empty() && !entry.mode.empty(); });
}

bool yomitan_parser::parse_kanji_bank(std::string_view content, std::vector<Kanji>& out) {
  auto error = glz::read<parse_options>(out, content);
  return !error && std::ranges::all_of(out, [](const auto& entry) { return !entry.character.empty(); });
}

bool yomitan_parser::parse_tag_bank(std::string_view content, std::vector<Tag>& out) {
  auto error = glz::read<parse_options>(out, content);
  return !error && std::ranges::all_of(out, [](const auto& entry) { return !entry.name.empty(); });
}

bool yomitan_parser::parse_frequency(std::string_view content, ParsedFrequency& out) {
  internal::RawFrequencyFlat parsed_flat;
  auto error =
      glz::read<parse_options>(parsed_flat, content);
  if (!error) {
    out.reading = parsed_flat.reading.value_or("");
    out.value = parsed_flat.value;
    out.display_value = parsed_flat.display_value.value_or(std::to_string(parsed_flat.value));
    return true;
  }

  int val;
  error = glz::read<parse_options>(val, content);
  if (!error) {
    out.value = val;
    out.display_value = std::to_string(val);
    out.reading = "";
    return true;
  }

  internal::RawFrequency parsed;
  error = glz::read<parse_options>(parsed, content);
  if (error) {
    return false;
  }

  out.reading = parsed.reading.value_or("");
  if (std::holds_alternative<int>(parsed.frequency)) {
    int freq = std::get<int>(parsed.frequency);
    out.value = freq;
    out.display_value = std::to_string(freq);
  } else {
    auto& freq = std::get<internal::FrequencyValue>(parsed.frequency);
    out.value = freq.value;
    out.display_value = freq.display_value.value_or(std::to_string(freq.value));
  }
  return true;
}

bool yomitan_parser::parse_pitch(std::string_view content, ParsedPitch& out) {
  internal::RawPitch parsed;
  auto error = glz::read<parse_options>(parsed, content);
  if (error) {
    return false;
  }

  auto to_number_array = [](const std::optional<std::variant<int, std::vector<int>>>& value) -> std::vector<int> {
    if (!value) {
      return {};
    }
    if (std::holds_alternative<int>(*value)) {
      return {std::get<int>(*value)};
    }
    return std::get<std::vector<int>>(*value);
  };

  out.reading = parsed.reading;
  out.pitches.clear();
  out.transcriptions.clear();
  for (auto& pitch : parsed.pitches) {
    ParsedAccent accent{.nasal = to_number_array(pitch.nasal), .devoice = to_number_array(pitch.devoice)};
    if (std::holds_alternative<int>(pitch.position)) {
      accent.position = std::get<int>(pitch.position);
    } else {
      accent.pattern = std::move(std::get<std::string>(pitch.position));
    }
    out.pitches.emplace_back(std::move(accent));
  }
  return true;
}

bool yomitan_parser::parse_ipa(std::string_view content, ParsedPitch& out) {
  internal::RawIPA parsed;
  auto error = glz::read<parse_options>(parsed, content);
  if (error) {
    return false;
  }

  out.reading = parsed.reading;
  out.pitches.clear();
  out.transcriptions =
      parsed.transcriptions | std::views::transform(&internal::TranscriptionsArray::ipa) | std::ranges::to<std::vector>();
  return true;
}
