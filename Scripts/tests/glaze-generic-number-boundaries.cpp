// Root runs this standalone regression with -fsanitize=undefined,float-cast-overflow.
#include <glaze/glaze.hpp>
#include <glaze/json/generic.hpp>

#include <cassert>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <stdexcept>
#include <vector>

template <class Generic, class Integer>
void accepted(const double value, const Integer expected)
{
    const Generic source(value);
    assert(source.template holds<double>());
    Integer result = 42;
    assert(!glz::convert_from_generic(result, source));
    assert(result == expected);
    result = 42;
    assert(!glz::read_json(result, source));
    assert(result == expected);
    const auto decoded = glz::read_json<Integer>(source);
    assert(decoded && *decoded == expected);
    assert(source.template as<Integer>() == expected);
}

template <class Generic, class Integer>
void rejected(const double value)
{
    const Generic source(value);
    Integer result = 42;
    const auto converted = glz::convert_from_generic(result, source);
    assert(converted.ec == glz::error_code::parse_number_failure);
    assert(result == 42);
    const auto read = glz::read_json(result, source);
    assert(read.ec == glz::error_code::parse_number_failure);
    assert(result == 42);
    const auto decoded = glz::read_json<Integer>(source);
    assert(!decoded && decoded.error().ec == glz::error_code::parse_number_failure);
#if __cpp_exceptions
    bool threw = false;
    try {
        (void)source.template as<Integer>();
    }
    catch (const std::runtime_error&) {
        threw = true;
    }
    assert(threw);
#endif
}

template <class Generic, class Integer>
void integer_boundaries()
{
    const auto infinity = std::numeric_limits<double>::infinity();
    const double upper = std::ldexp(1.0, std::numeric_limits<Integer>::digits);
    const double inside_upper = std::nextafter(upper, 0.0);
    accepted<Generic, Integer>(0.0, 0);
    accepted<Generic, Integer>(-0.0, 0);
    accepted<Generic, Integer>(12.875, 12);
    accepted<Generic, Integer>(-0.875, 0);
    accepted<Generic, Integer>(inside_upper, static_cast<Integer>(inside_upper));
    rejected<Generic, Integer>(upper);
    rejected<Generic, Integer>(std::nextafter(upper, infinity));
    rejected<Generic, Integer>(std::numeric_limits<double>::max());
    rejected<Generic, Integer>(-std::numeric_limits<double>::max());
    rejected<Generic, Integer>(infinity);
    rejected<Generic, Integer>(-infinity);
    rejected<Generic, Integer>(std::numeric_limits<double>::quiet_NaN());
    if constexpr (std::is_signed_v<Integer>) {
        const double lower = -upper;
        accepted<Generic, Integer>(lower, std::numeric_limits<Integer>::min());
        accepted<Generic, Integer>(-12.875, -12);
        // For small integers, a value below min still truncates to min.
        if constexpr (std::numeric_limits<Integer>::digits < std::numeric_limits<double>::digits) {
            accepted<Generic, Integer>(lower - 0.75, std::numeric_limits<Integer>::min());
            rejected<Generic, Integer>(lower - 1.0);
        }
        else {
            rejected<Generic, Integer>(std::nextafter(lower, -infinity));
        }
    }
    else {
        rejected<Generic, Integer>(-1.0);
        rejected<Generic, Integer>(std::nextafter(-1.0, -infinity));
    }
}

template <class Generic>
void number_mode()
{
    integer_boundaries<Generic, int8_t>();
    integer_boundaries<Generic, uint8_t>();
    integer_boundaries<Generic, int16_t>();
    integer_boundaries<Generic, uint16_t>();
    integer_boundaries<Generic, int32_t>();
    integer_boundaries<Generic, uint32_t>();
    integer_boundaries<Generic, int64_t>();
    integer_boundaries<Generic, uint64_t>();

    const Generic array(typename Generic::array_t{Generic(1.875), Generic(-2.875)});
    std::vector<int> values;
    assert(!glz::read_json(values, array));
    assert((values == std::vector<int>{1, -2}));
    const Generic invalid_array(typename Generic::array_t{Generic(1.0), Generic(1e300)});
    assert(glz::read_json(values, invalid_array).ec == glz::error_code::parse_number_failure);

    Generic object;
    object["value"] = 12.875;
    std::map<std::string, int> mapped;
    assert(!glz::read_json(mapped, object));
    assert(mapped.at("value") == 12);
    object["value"] = 1e300;
    assert(glz::read_json(mapped, object).ec == glz::error_code::parse_number_failure);
    assert(mapped.at("value") == 12);

    // The guard is integer-only; floating and boolean conversions retain their contracts.
    const Generic infinite(std::numeric_limits<double>::infinity());
    double floating = 0;
    assert(!glz::read_json(floating, infinite));
    assert(floating == std::numeric_limits<double>::infinity());
    const Generic nan(std::numeric_limits<double>::quiet_NaN());
    assert(std::isnan(nan.template as<double>()));
    assert(nan.template as<bool>());
}

int main()
{
    number_mode<glz::generic>();
    number_mode<glz::generic_i64>();
    number_mode<glz::generic_u64>();
    number_mode<glz::generic_sorted>();
    number_mode<glz::generic_sorted_i64>();
    number_mode<glz::generic_sorted_u64>();

    // Integer-stored alternatives retain their existing conversion behavior.
    glz::generic_u64 unsigned_source(std::numeric_limits<uint64_t>::max());
    uint64_t unsigned_result = 0;
    assert(!glz::read_json(unsigned_result, unsigned_source));
    assert(unsigned_result == std::numeric_limits<uint64_t>::max());
    assert(unsigned_source.as<uint64_t>() == unsigned_result);
    int64_t narrowed = 0;
    assert(!glz::read_json(narrowed, unsigned_source));
    assert(narrowed == static_cast<int64_t>(unsigned_result));
    glz::generic_i64 signed_source(std::numeric_limits<int64_t>::min());
    int64_t signed_result = 0;
    assert(!glz::read_json(signed_result, signed_source));
    assert(signed_result == std::numeric_limits<int64_t>::min());
    assert(signed_source.as<int64_t>() == signed_result);

    glz::generic ordinary;
    assert(!glz::read_json(ordinary, R"({"frequency":42,"score":1.25,"term":"word"})"));
    int frequency = 0;
    assert(!glz::read_json(frequency, ordinary["frequency"]));
    assert(frequency == 42);
    const auto serialized = ordinary.dump();
    assert(serialized && *serialized == R"({"frequency":42,"score":1.25,"term":"word"})");
}
