#pragma once
#include <cstdint>
#include <glaze/glaze.hpp>
#include <optional>
#include <string_view>
#include <vector>

struct Index {
  std::string title;
  std::optional<int> format;
  std::optional<int> version;
  std::string revision;
  std::optional<std::string> minimumYomitanVersion;
  bool sequenced = false;
  std::optional<bool> isUpdatable;
  std::optional<std::string> indexUrl;
  std::optional<std::string> downloadUrl;
  std::optional<std::string> author;
  std::optional<std::string> url;
  std::optional<std::string> description;
  std::optional<std::string> attribution;
  std::optional<std::string> sourceLanguage;
  std::optional<std::string> targetLanguage;
  std::optional<std::string> frequencyMode;
};

struct Term {
  std::string expression;
  std::string reading;
  std::optional<std::string> definition_tags;
  std::string rules;
  double score = 0;
  glz::raw_json_view glossary;
  int64_t sequence = 0;
  std::string term_tags;
};

struct Meta {
  std::string expression;
  std::string mode;
  glz::raw_json_view data;
};

struct Kanji {
  std::string character;
  std::string onyomi;
  std::string kunyomi;
  std::string tags;
  std::vector<std::string> definitions;
  std::unordered_map<std::string, std::string> stats;
};

struct Tag {
  std::string name;
  std::string category;
  int order = 0;
  std::string notes;
  int score = 0;
};

struct ParsedFrequency {
  std::string reading;
  int value;
  std::string display_value;
};

struct ParsedAccent {
  int position = 0;
  std::string pattern;
  std::vector<int> nasal;
  std::vector<int> devoice;
};

struct ParsedPitch {
  std::string reading;
  std::vector<ParsedAccent> pitches;
  std::vector<std::string> transcriptions;
};

namespace yomitan_parser {
bool parse_index(std::string_view content, Index& out);
bool parse_term_bank(std::string_view content, std::vector<Term>& out);
bool parse_meta_bank(std::string_view content, std::vector<Meta>& out);
bool parse_kanji_bank(std::string_view content, std::vector<Kanji>& out);
bool parse_tag_bank(std::string_view content, std::vector<Tag>& out);
bool parse_frequency(std::string_view content, ParsedFrequency& out);
bool parse_pitch(std::string_view content, ParsedPitch& out);
bool parse_ipa(std::string_view content, ParsedPitch& out);
};
