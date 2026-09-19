// Run with clang++ -std=c++23 -fsanitize=address,undefined and the vendored
// HoshiDicts external/utfcpp/source, unordered_dense/include and glaze/include paths.
#include <utf8.h>
#include <ankerl/unordered_dense.h>
#include <glaze/glaze.hpp>
#include <cassert>
#include <limits>
#include <unordered_map>

int main() {
    for (std::u16string malformed : {std::u16string{0xdc00, u'A'}, std::u16string{0xd800, u'A'}}) {
        auto it = malformed.begin();
        bool rejected = false;
        try { (void)utf8::next16(it, malformed.end()); }
        catch (const utf8::invalid_utf16&) { rejected = true; }
        assert(rejected);
        assert(it == malformed.begin());
    }
    std::u16string valid{0xd83d, 0xde00, u'A'};
    auto it = valid.begin();
    assert(utf8::next16(it, valid.end()) == 0x1f600);
    assert(utf8::next16(it, valid.end()) == u'A');
    bool exhausted = false;
    try { (void)utf8::next16(it, valid.end()); }
    catch (const utf8::not_enough_room&) { exhausted = true; }
    assert(exhausted);
    assert(utf8::utf32to8(utf8::utf8to32(std::string("가😀字"))) == "가😀字");
    for (const auto& malformed : {std::string("\xc0\x80"), std::string("\xed\xa0\x80"), std::string("\xf4\x90\x80\x80")}) {
        assert(!utf8::is_valid(malformed));
    }
    ankerl::unordered_dense::map<uint64_t, std::vector<char>> dense;
    for (uint64_t i = 0; i < 20000; ++i) dense[i] = {'a', char(i % 127)};
    for (uint64_t i = 0; i < 20000; i += 2) assert(dense.erase(i) == 1);
    for (uint64_t i = 1; i < 20000; i += 2) assert(dense.at(i)[1] == char(i % 127));
    auto copied = dense;
    assert(copied == dense);
    dense.clear();
    dense.reserve(40000);
    assert(dense.empty());
    std::vector<glz::raw_json> entries;
    assert(!glz::read_json(entries, std::string_view(R"([{"glossary":["word"],"n":1}])")));
    assert(glz::read_json(entries, std::string_view(R"([{"glossary":["word"])")));
    for (int64_t value : {std::numeric_limits<int64_t>::min(), int64_t(-1), int64_t(0), std::numeric_limits<int64_t>::max()}) {
        char buffer[32];
        auto end = glz::to_chars(buffer, value);
        assert(std::string(buffer, end) == std::to_string(value));
    }
}
