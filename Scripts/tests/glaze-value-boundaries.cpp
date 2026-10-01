// Standalone regression; run with address/undefined-behavior sanitizers.
#include <glaze/glaze.hpp>
#include <glaze/beve.hpp>
#include <bitset>
#include <cassert>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

template <size_t N>
static void bitset_round_trip(const std::bitset<N>& input) {
    const auto encoded = glz::write_beve(input);
    assert(encoded);
    std::bitset<N> decoded;
    assert(!glz::read_beve(decoded, *encoded));
    assert(decoded == input);
    const auto reencoded = glz::write_beve(decoded);
    assert(reencoded && *reencoded == *encoded);
}

static void bitset_boundaries() {
    bitset_round_trip(std::bitset<0>{});
    bitset_round_trip(std::bitset<3>{5});
    bitset_round_trip(std::bitset<8>{0xa5});
    bitset_round_trip(std::bitset<65>{}.set());

    const auto oversized = glz::write_beve(std::bitset<8>{0xff});
    assert(oversized);
    std::bitset<3> small{5};
    const auto original = small;
    const auto error = glz::read_beve(small, *oversized);
    assert(error.ec == glz::error_code::exceeded_static_array_size);
    assert(small == original);

    const auto across_word = glz::write_beve(std::bitset<65>{}.set());
    assert(across_word);
    std::bitset<64> word;
    assert(glz::read_beve(word, *across_word).ec == glz::error_code::exceeded_static_array_size);

    // A smaller source changes only its own bits and consumes only its payload.
    const auto prefix = glz::write_beve(std::bitset<3>{5});
    const auto next = glz::write_beve(uint32_t{42});
    assert(prefix && next);
    const auto stream = *prefix + *next;
    std::bitset<17> larger;
    larger.set(16);
    const auto consumed = glz::read_beve_at(larger, stream);
    assert(consumed && *consumed == prefix->size());
    assert(larger.to_ulong() == ((1ul << 16) | 5ul));
    uint32_t following = 0;
    assert(glz::read_beve_at(following, stream, *consumed));
    assert(following == 42);

    const auto empty = glz::write_beve(std::bitset<0>{});
    assert(empty);
    const auto empty_stream = *empty + *next;
    const auto before_empty = larger;
    const auto empty_consumed = glz::read_beve_at(larger, empty_stream);
    assert(empty_consumed && *empty_consumed == empty->size());
    assert(larger == before_empty);

    auto truncated = *across_word;
    truncated.pop_back();
    std::bitset<65> incomplete;
    assert(glz::read_beve(incomplete, truncated));
}

static void integer_boundaries() {
    constexpr auto maximum = std::numeric_limits<uint64_t>::max();
    assert(glz::stoui("18446744073709551615") == maximum);
    assert(!glz::stoui("18446744073709551616"));
    assert(!glz::stoui("100000000000000000000"));
    assert(!glz::stoui("184467440737095516150"));
    assert(!glz::stoui(std::string(80, '9')));
    // Decimal placement still accounts for a negative exponent after a long
    // mantissa; keeping only its first 20 digits must not divide it twice.
    assert(glz::stoui("184467440737095516150e-1") == maximum);
    assert(glz::stoui("100000000000000000000e-1") == 10000000000000000000ull);
    assert(glz::stoui("12345e-2") == 123);
    assert(glz::stoui("1.234e2") == 123);
    assert(glz::stoui("12abc") == 12);
    assert(glz::stoui("0") == 0);
    assert(!glz::stoui("1e256"));

    // stoui is used by JSON pointer validation, independently of JSON numeric
    // decoding (which calls glz::atoi). An overflowing index is not valid.
    const bool valid_index = glz::valid<std::vector<int>, "/12">();
    const bool overflow_index = glz::valid<std::vector<int>, "/100000000000000000000">();
    assert(valid_index);
    assert(!overflow_index);

    uint64_t value = 0;
    assert(!glz::read_json(value, std::string{"18446744073709551615"}));
    assert(value == maximum);
    assert(glz::read_json(value, std::string{"100000000000000000000"}));
    const auto json = glz::write_json(maximum);
    assert(json && *json == "18446744073709551615");
}

int main() {
    bitset_boundaries();
    integer_boundaries();
}
