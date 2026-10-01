// clang++ -std=c++17 -fsanitize=address,undefined -I Vendor/HoshiDicts/external/unordered_dense/include Scripts/tests/unordered-segment-allocation-regression.cpp -o /tmp/unordered-segment-allocation-regression
#include <ankerl/unordered_dense.h>
#include <cassert>
#include <cstddef>
#include <memory>
#include <new>
#include <type_traits>

struct AllocationState {
    bool fail_segment = false;
    bool fail_table = false;
    std::size_t segments_allocated = 0;
    std::size_t segments_freed = 0;
    std::size_t tables_allocated = 0;
    std::size_t tables_freed = 0;
    std::size_t segment_attempts = 0;
    std::size_t table_attempts = 0;
};

template <class T>
struct FailureAllocator {
    using value_type = T;
    AllocationState* state = nullptr;

    FailureAllocator() = default;
    explicit FailureAllocator(AllocationState& value) noexcept : state(&value) {}
    template <class U>
    FailureAllocator(const FailureAllocator<U>& other) noexcept : state(other.state) {}

    T* allocate(std::size_t count) {
        assert(state != nullptr);
        if constexpr (std::is_pointer_v<T>) {
            ++state->table_attempts;
            if (state->fail_table) throw std::bad_alloc();
        } else {
            ++state->segment_attempts;
            if (state->fail_segment) throw std::bad_alloc();
        }
        T* result = std::allocator<T>{}.allocate(count);
        if constexpr (std::is_pointer_v<T>) ++state->tables_allocated;
        else ++state->segments_allocated;
        return result;
    }

    void deallocate(T* pointer, std::size_t count) noexcept {
        if constexpr (std::is_pointer_v<T>) ++state->tables_freed;
        else ++state->segments_freed;
        std::allocator<T>{}.deallocate(pointer, count);
    }

    template <class U>
    bool operator==(const FailureAllocator<U>& other) const noexcept { return state == other.state; }
    template <class U>
    bool operator!=(const FailureAllocator<U>& other) const noexcept { return !(*this == other); }
};

using Segments = ankerl::unordered_dense::segmented_vector<int, FailureAllocator<int>, 16>;

int main() {
    AllocationState state;
    {
        Segments values{FailureAllocator<int>{state}};
        // A segment succeeds, then inserting its pointer cannot allocate.
        // The original implementation loses that segment even after destruction.
        state.fail_table = true;
        bool rejected = false;
        try { values.emplace_back(17); }
        catch (const std::bad_alloc&) { rejected = true; }
        assert(rejected && values.empty() && values.capacity() == 0);
        assert(state.segment_attempts == 1 && state.table_attempts == 1);
        assert(state.segments_allocated == 1 && state.segments_freed == 1);
        assert(state.tables_allocated == 0 && state.tables_freed == 0);

        // Failure in the first allocation must not attempt the pointer table.
        state.fail_table = false;
        state.fail_segment = true;
        rejected = false;
        try { values.emplace_back(17); }
        catch (const std::bad_alloc&) { rejected = true; }
        assert(rejected && values.empty() && values.capacity() == 0);
        assert(state.segment_attempts == 2 && state.table_attempts == 1);
        assert(state.segments_allocated == state.segments_freed);

        state.fail_segment = false;
        for (int value = 0; value < 4; ++value) values.emplace_back(value);
        const int* first = &values[0];

        // Exercise pointer-table failure with live elements too. Existing table
        // spare capacity may allow several segments before the next growth.
        state.fail_table = true;
        rejected = false;
        for (int value = 4; value < 4096 && !rejected; ++value) {
            const auto size = values.size();
            const auto capacity = values.capacity();
            const auto live_segments = state.segments_allocated - state.segments_freed;
            const auto live_tables = state.tables_allocated - state.tables_freed;
            try { values.emplace_back(value); }
            catch (const std::bad_alloc&) {
                rejected = true;
                assert(values.size() == size && values.capacity() == capacity);
                assert(state.segments_allocated - state.segments_freed == live_segments);
                assert(state.tables_allocated - state.tables_freed == live_tables);
            }
        }
        assert(rejected && &values[0] == first);
        for (std::size_t i = 0; i < values.size(); ++i) assert(values[i] == static_cast<int>(i));

        // A failed append leaves the same vector usable and its references valid.
        state.fail_table = false;
        const auto next = values.size();
        values.emplace_back(static_cast<int>(next));
        assert(values.size() == next + 1 && values[next] == static_cast<int>(next));
        assert(&values[0] == first);
    }
    assert(state.segments_allocated == state.segments_freed);
    assert(state.tables_allocated == state.tables_freed);
}
