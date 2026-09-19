// clang++ -std=c++23 -fsanitize=address,undefined -I Vendor/HoshiDicts/external/glaze/include Scripts/tests/hoshi-reader-boundaries.cpp -o /tmp/hoshi-reader-boundaries
#include <glaze/glaze.hpp>
#include <cassert>
#include <map>
struct Columns { std::vector<std::array<int, 2>> points; };
struct Empty {};
struct MixedColumns { std::vector<std::array<int, 2>> points; std::vector<int> z; };
struct NestedColumns { std::vector<std::vector<int>> points; };
enum class Reordered { a, b, c };
template <> struct glz::meta<Reordered> {
    static constexpr auto value = glz::enumerate("c", Reordered::c, "a", Reordered::a, "b", Reordered::b);
};
int main() {
    for (auto s : {"[0e1]", "[-0E+2]", "[0e-2]", "[1e1]", "[0.0e1]"}) assert(!glz::validate_json(std::string_view{s}));
    for (auto s : {"[0e]", "[-0E+]", "[01]", "[0.]"}) assert(glz::validate_json(std::string_view{s}));
    for (auto s : {"\"text", "\"text\"\"", "\""}) {
        std::string out;
        assert(glz::read_csv(out, std::string_view{s}));
    }
    std::string text;
    assert(!glz::read_csv(text, std::string_view{"\"a\"\"b\""}));
    assert(text == "a\"b");
    std::map<std::string, std::vector<int>> columns;
    auto empty = glz::write_csv<glz::colwise>(columns);
    assert(empty && empty->empty());
    Empty none;
    assert(glz::write_csv<glz::colwise>(none)->empty());
    assert(glz::read_csv<glz::colwise>(columns, std::string_view{"\n1"}));
    assert(glz::read_csv<glz::colwise>(columns, std::string_view{"a\nx"}));
    assert(*glz::write_json(Reordered::a) == "\"a\"");
    assert(*glz::write_json(Reordered::b) == "\"b\"");
    std::map<std::string, std::string> object{{"long", std::string(1000, 'x')}};
    std::array<char, 32> shortBuffer{};
    assert(!glz::write_as<glz::opts{}>(object, "/long", shortBuffer));
    std::string fullBuffer;
    assert(glz::write_as<glz::opts{}>(object, "/long", fullBuffer));
    Columns points;
    auto headers = glz::write_csv<glz::colwise>(points);
    assert(headers && *headers == "points[0],points[1]\n");
    points.points.push_back({1, 2});
    assert(*glz::write_csv<glz::colwise>(points) == "points[0],points[1]\n1,2\n");
    assert(*glz::write_csv(points) == "points[0],1\npoints[1],2\n");
    points.points.clear();
    assert(*glz::write_csv(points) == "points[0],\npoints[1],\n");
    MixedColumns mixed{{{1, 2}}, {3}};
    assert(*glz::write_csv<glz::colwise>(mixed) == "points[0],points[1],z\n1,2,3\n");
    assert(*glz::write_csv(mixed) == "points[0],1\npoints[1],2\nz,3\n");
    mixed.z.clear();
    assert(!glz::write_csv<glz::colwise>(mixed));
    std::map<std::string, std::vector<int>> ragged{{"a", {1, 2}}, {"b", {3}}};
    assert(!glz::write_csv<glz::colwise>(ragged));
    NestedColumns nested;
    assert(glz::write_csv(nested)->empty());
    nested.points = {{1, 2}, {3}};
    assert(!glz::write_csv(nested));
    int invoked = -1;
    std::function<void(int)> f = [&](int n) { invoked = n; };
    glz::invoke_t<std::function<void(int)>> invoke{f};
    assert(*glz::write_json(invoke) == "[0]");
    assert(!glz::read_json(invoke, std::string_view{"[7]"}) && invoked == 7);
    glz::invoke_update<void(int)> update{f};
    assert(*glz::write_json(update) == "[0]");
    assert(!glz::read_json(update, std::string_view{"[1]"}) && invoked == 7);
    assert(!glz::read_json(update, std::string_view{"[2]"}) && invoked == 2);
    std::array<char, 2048> rawStorage{};
    char* rawBuffer = rawStorage.data();
    assert(glz::write_as<glz::opts{}>(object, "/long", rawBuffer));
    assert(!glz::write_as<glz::opts{}>(object, "/missing", fullBuffer));
    std::vector<glz::raw_json> entries;
    assert(!glz::read_json(entries, std::string_view{"[0e1,{\"title\":\"日本語\"}]"}));
    assert(entries.size() == 2 && entries[0].str == "0e1");
}
