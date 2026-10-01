// clang++ -std=c++23 -fsanitize=address,undefined -I Vendor/HoshiDicts/external/glaze/include Scripts/tests/glaze-map-boundaries.cpp -o /tmp/glaze-map-boundaries
#include <glaze/containers/ordered_small_map.hpp>
#include <cassert>
#include <string>
#include <string_view>

using Map = glz::ordered_small_map<int>;

template <class Duplicate>
void check_erase_and_reinsert(Duplicate duplicate, int expected) {
    // Use several distinct keys so a bloom false positive cannot hide a stale
    // filter. No lookup may rebuild the index between the final two insertions.
    for (int trial = 0; trial < 32; ++trial) {
        for (bool range_erase : {false, true}) {
            Map map;
            for (int i = 0; i < 10; ++i) map.try_emplace("seed-" + std::to_string(i), i);
            assert(map.find("seed-0") != map.end()); // materialize the >8-entry index
            if (range_erase) {
                map.erase(map.begin() + 8, map.end());
            } else {
                map.erase(map.begin() + 8);
                map.erase(map.begin() + 8);
            }
            assert(map.size() == 8);
            const auto key = "new-key-" + std::to_string(trial);
            assert(map.try_emplace(key, 42).second); // linear path, size becomes 9
            duplicate(map, key);
            assert(map.size() == 9);
            assert(map.at(key) == expected);
            for (int i = 0; i < 8; ++i) {
                assert(map.begin()[i].first == "seed-" + std::to_string(i));
                assert(map.begin()[i].second == i);
            }
            assert(map.begin()[8].first == key); // original insertion order survives
            // The rebuilt bloom/index must still admit genuinely new keys.
            assert(map.try_emplace("another-key", 7).second);
            assert(map.size() == 10 && map.at("another-key") == 7);
        }
    }
}

int main() {
    check_erase_and_reinsert([](Map& map, const std::string& key) {
        const Map::value_type pair{key, 99};
        assert(!map.insert(pair).second);
    }, 42);
    check_erase_and_reinsert([](Map& map, const std::string& key) {
        assert(!map.insert(Map::value_type{key, 99}).second);
    }, 42);
    check_erase_and_reinsert([](Map& map, const std::string& key) {
        assert(!map.try_emplace(key, 99).second);
    }, 42);
    check_erase_and_reinsert([](Map& map, const std::string& key) {
        assert(!map.insert_or_assign(key, 99).second);
    }, 99);
    check_erase_and_reinsert([](Map& map, const std::string& key) {
        assert(!map.insert_or_assign(std::string(key), 99).second);
    }, 99);
    check_erase_and_reinsert([](Map& map, const std::string& key) { map[key] = 99; }, 99);
    check_erase_and_reinsert([](Map& map, const std::string& key) { map[std::string(key)] = 99; }, 99);
    check_erase_and_reinsert([](Map& map, const std::string& key) { map[std::string_view(key)] = 99; }, 99);
}
