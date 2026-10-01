// clang++ -std=c++23 -fsanitize=address,undefined -I Vendor/HoshiDicts/external/glaze/include Scripts/tests/glaze-compressed-boundaries.cpp -o /tmp/glaze-compressed-boundaries
#include <glaze/glaze.hpp>
#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <memory>

// Pointer-formation UB need not be caught by a sanitizer when the invalid pointer
// is only compared. This cursor also records attempts to advance beyond the range,
// without itself forming an invalid pointer. memcpy still reads the real buffer.
struct CheckedCursor {
    const unsigned char* data;
    size_t length;
    size_t position;
    bool* invalid_advance;

    operator const void*() const noexcept {
        assert(position <= length);
        return data + position;
    }
    CheckedCursor& operator+=(size_t count) noexcept {
        if (position > length || count > length - position) *invalid_advance = true;
        position += count;
        return *this;
    }
    CheckedCursor& operator++() noexcept { return *this += 1; }
    CheckedCursor operator+(size_t count) const noexcept {
        auto result = *this;
        result += count;
        return result;
    }
    friend bool operator>=(const CheckedCursor& a, const CheckedCursor& b) noexcept {
        return a.position >= b.position;
    }
    friend bool operator>(const CheckedCursor& a, const CheckedCursor& b) noexcept {
        return a.position > b.position;
    }
    friend ptrdiff_t operator-(const CheckedCursor& a, const CheckedCursor& b) noexcept {
        return ptrdiff_t(a.position) - ptrdiff_t(b.position);
    }
};

struct Fixture {
    std::array<unsigned char, 8> wire;
    size_t width;
    uint64_t value;
};

template <class Cursor>
void check_decode(Cursor begin, Cursor end, const Fixture& fixture, size_t available) {
    auto it = begin;
    glz::context ctx;
    const auto result = glz::int_from_compressed(ctx, it, end);
    if (available < fixture.width) {
        assert(ctx.error == glz::error_code::unexpected_end);
        assert(result == 0 && it - begin == 0);
    } else if (fixture.width == 8 && sizeof(size_t) <= sizeof(uint32_t)) {
        assert(ctx.error == glz::error_code::invalid_length);
        assert(result == 0 && it - begin == 0);
    } else if (fixture.value > (uint64_t{1} << 48)) {
        assert(ctx.error == glz::error_code::unexpected_end);
        assert(result == 0 && it - begin == ptrdiff_t(fixture.width));
    } else {
        assert(ctx.error == glz::error_code::none);
        assert(result == fixture.value && it - begin == ptrdiff_t(fixture.width));
    }
}

template <class Cursor>
void check_skip(Cursor begin, Cursor end, const Fixture& fixture, size_t available) {
    auto it = begin;
    glz::context ctx;
    glz::skip_compressed_int(ctx, it, end);
    if (available < fixture.width) {
        assert(ctx.error == glz::error_code::unexpected_end);
        assert(it - begin == 0);
    } else {
        // Skip intentionally does not impose the decoder's numeric safety limit.
        assert(ctx.error == glz::error_code::none);
        assert(it - begin == ptrdiff_t(fixture.width));
    }
}

int main() {
    // Fixed little-endian wire bytes: all four widths, zero, upper boundaries,
    // the inclusive 2^48 safety limit, and the immediately rejected value.
    const Fixture fixtures[] = {
        {{0x00}, 1, 0},
        {{0xfc}, 1, 63},
        {{0x01, 0x00}, 2, 0},
        {{0x01, 0x01}, 2, 64},
        {{0xfd, 0xff}, 2, 16'383},
        {{0x02, 0x00, 0x00, 0x00}, 4, 0},
        {{0x02, 0x00, 0x01, 0x00}, 4, 16'384},
        {{0xfe, 0xff, 0xff, 0xff}, 4, (uint64_t{1} << 30) - 1},
        {{0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}, 8, 0},
        {{0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00}, 8, uint64_t{1} << 30},
        {{0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00}, 8, uint64_t{1} << 48},
        {{0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00}, 8, (uint64_t{1} << 48) + 1},
    };
    for (const auto& fixture : fixtures) {
        // Every truncated length plus exact-end and a trailing sentinel. Allocate
        // precisely the readable bytes so ASan can also catch actual overreads.
        for (size_t available = 0; available <= fixture.width + 1; ++available) {
            auto storage = std::make_unique<unsigned char[]>(available == 0 ? 1 : available);
            for (size_t i = 0; i < available; ++i) {
                storage[i] = i < fixture.width ? fixture.wire[i] : 0xa5;
            }
            const auto* begin = storage.get();
            const auto* end = begin + available;
            check_decode(begin, end, fixture, available);
            check_skip(begin, end, fixture, available);

            bool invalid_advance = false;
            const CheckedCursor checked_begin{begin, available, 0, &invalid_advance};
            const CheckedCursor checked_end{begin, available, available, &invalid_advance};
            check_decode(checked_begin, checked_end, fixture, available);
            check_skip(checked_begin, checked_end, fixture, available);
            assert(!invalid_advance);
            for (size_t i = 0; i < available; ++i) {
                assert(storage[i] == (i < fixture.width ? fixture.wire[i] : 0xa5));
            }
        }
    }
}
