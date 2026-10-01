// Run with undefined-behavior sanitizer to cover invalid external enum/variant IDs.
#include <glaze/glaze.hpp>
#include <cassert>
#include <cstdint>
#include <limits>
#include <variant>

constexpr auto lowest = std::numeric_limits<int64_t>::min();
constexpr auto highest = std::numeric_limits<int64_t>::max();
enum class Offset : int64_t { a = 1, b = 2, c = 3 };
enum class Sparse : int64_t { a = 1, b = 3, c = 6 };
enum class Wide : int64_t { a = lowest, b = 0, c = highest };

template <> struct glz::meta<Offset> {
    static constexpr auto value = glz::enumerate("a", Offset::a, "b", Offset::b, "c", Offset::c);
};
template <> struct glz::meta<Sparse> {
    static constexpr auto value = glz::enumerate("a", Sparse::a, "b", Sparse::b, "c", Sparse::c);
};
template <> struct glz::meta<Wide> {
    static constexpr auto value = glz::enumerate("a", Wide::a, "b", Wide::b, "c", Wide::c);
};

using OffsetVariant = std::variant<int, bool, double>;
using SparseVariant = std::variant<bool, double, int>;
using WideVariant = std::variant<double, int, bool>;
template <> struct glz::meta<OffsetVariant> {
    static constexpr std::array<int64_t, 3> ids{1, 2, 3};
};
template <> struct glz::meta<SparseVariant> {
    static constexpr std::array<int64_t, 3> ids{1, 3, 6};
};
template <> struct glz::meta<WideVariant> {
    static constexpr std::array<int64_t, 3> ids{lowest, 0, highest};
};

int main() {
    for (auto value : {lowest, highest, int64_t{-1}, int64_t{0}, int64_t{4}}) {
        assert(glz::get_enum_name(static_cast<Offset>(value)).empty());
        assert(glz::variant_id_to_index<OffsetVariant>::op(value) >= 3);
    }
    for (auto value : {lowest, highest, int64_t{-1}, int64_t{0}, int64_t{2}}) {
        assert(glz::get_enum_name(static_cast<Sparse>(value)).empty());
        assert(glz::variant_id_to_index<SparseVariant>::op(value) >= 3);
    }
    assert(glz::get_enum_name(Offset::a) == "a");
    assert(glz::get_enum_name(Offset::c) == "c");
    assert(glz::get_enum_name(Sparse::b) == "b");
    assert(glz::get_enum_name(Wide::a) == "a");
    assert(glz::get_enum_name(Wide::b) == "b");
    assert(glz::get_enum_name(Wide::c) == "c");
    assert(glz::get_enum_name(static_cast<Wide>(1)).empty());
    assert(glz::variant_id_to_index<OffsetVariant>::op(2) == 1);
    assert(glz::variant_id_to_index<SparseVariant>::op(6) == 2);
    assert(glz::variant_id_to_index<WideVariant>::op(lowest) == 0);
    assert(glz::variant_id_to_index<WideVariant>::op(0) == 1);
    assert(glz::variant_id_to_index<WideVariant>::op(highest) == 2);
}
