// Standalone regression; run with address/undefined-behavior sanitizers.
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <glaze/util/bit_array.hpp>
#include <cassert>

template <size_t N, std::unsigned_integral Chunk = uint64_t>
void check_trailing_zero_boundaries() {
    using Bits = glz::bit_array<N, Chunk>;
    Bits bits;
    // Zero keeps the existing storage-width result, including unused high bits.
    constexpr int storage_width = Bits::n_chunks * Bits::n_chunk_bits;
    assert(bits.countr_zero() == storage_width);

    // Every index covers the first bit, both sides of every chunk boundary,
    // and the final valid bit when the last chunk is only partially used.
    for (size_t bit = 0; bit < N; ++bit) {
        bits[bit] = true;
        assert(bits.countr_zero() == static_cast<int>(bit));
        // A lower set bit must win even when a higher chunk is also nonzero.
        if (bit != 0) {
            bits[0] = true;
            assert(bits.countr_zero() == 0);
            bits[0] = false;
        }
        bits[bit] = false;
        assert(bits.countr_zero() == storage_width);
    }

    // Successively clear the lowest set bit across multiple occupied chunks.
    for (size_t bit = 0; bit < N; ++bit) bits[bit] = true;
    for (size_t bit = 0; bit < N; ++bit) {
        assert(bits.countr_zero() == static_cast<int>(bit));
        bits[bit] = false;
    }
    assert(bits.countr_zero() == storage_width);
}

int main() {
    check_trailing_zero_boundaries<0>();
    check_trailing_zero_boundaries<1>();
    check_trailing_zero_boundaries<63>();
    check_trailing_zero_boundaries<64>();
    check_trailing_zero_boundaries<65>();
    check_trailing_zero_boundaries<127>();
    check_trailing_zero_boundaries<128>();
    check_trailing_zero_boundaries<129>();
    check_trailing_zero_boundaries<17, uint8_t>();
    check_trailing_zero_boundaries<33, uint16_t>();
    check_trailing_zero_boundaries<65, uint32_t>();
}
