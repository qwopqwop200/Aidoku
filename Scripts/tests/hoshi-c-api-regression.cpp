#include "hoshidicts_c.h"
#include "hash/hash.hpp"
#include <xxh3.h>
#include <cassert>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <unistd.h>

static void save(const std::filesystem::path& path, const std::string& value) {
    std::ofstream stream(path, std::ios::binary);
    stream.write(value.data(), value.size());
    assert(stream.good());
}
int main() {
    assert(hd_import(nullptr, "/tmp", 0) == nullptr);
    assert(hd_query_add_term_dict(nullptr, "missing") == 1);
    assert(hd_lookup_new(nullptr, nullptr) == nullptr);
    const hd_term_result* terms = reinterpret_cast<const hd_term_result*>(1);
    size_t count = 123;
    assert(hd_query_run(nullptr, "a", &terms, &count) == nullptr && !terms && count == 0);
    auto* query = hd_query_new();
    assert(query);
    assert(hd_query_run(query, "a", nullptr, &count) == nullptr);
    assert(hd_query_run(query, nullptr, &terms, &count) == nullptr && !terms && count == 0);
    auto* empty = hd_query_run(query, "a", &terms, &count);
    assert(empty && count == 0);
    hd_results_free(empty);
    const hd_kanji_entry* kanji = reinterpret_cast<const hd_kanji_entry*>(1);
    count = 123;
    assert(!hd_query_run_kanji(nullptr, "a", &kanji, &count) && !kanji && count == 0);
    const hd_dictionary_style* styles = reinterpret_cast<const hd_dictionary_style*>(1);
    count = 123;
    assert(!hd_query_get_styles(nullptr, &styles, &count) && !styles && count == 0);
    assert(hd_query_get_media_file(nullptr, "a", "b").data == nullptr);
    const auto root = std::filesystem::temp_directory_path() / ("aidoku-hoshi-capi-" + std::to_string(getpid()));
    std::filesystem::create_directory(root);
    save(root/"index.json", R"({"title":"C API"})");
    save(root/".hoshidicts_3", "");
    const auto hash = XXH3_64bits("a", 1);
    hash::linear table;
    table.build_to_file({{hash, 1}}, root/"hash.table");
    hash::bloom::build_to_file({hash}, root/"bloom.filter");
    std::string broken(14, '\0');
    uint32_t one = 1; uint64_t record = 13;
    std::memcpy(broken.data()+1, &one, sizeof(one));
    std::memcpy(broken.data()+5, &record, sizeof(record));
    save(root/"blobs.bin", broken);
    assert(hd_query_add_term_dict(query, (root/"missing").c_str()) == 1);
    assert(hd_query_add_term_dict(query, root.c_str()) == 0);
    terms = reinterpret_cast<const hd_term_result*>(1); count = 123;
    assert(!hd_query_run(query, "a", &terms, &count) && !terms && count == 0);
    auto* deinflector = hd_deinflector_new(); assert(deinflector);
    auto* lookup = hd_lookup_new(query, deinflector); assert(lookup);
    const hd_lookup_result* results = reinterpret_cast<const hd_lookup_result*>(1); count = 123;
    assert(!hd_lookup_run(lookup, "a", 16, 16, &results, &count) && !results && count == 0);
    results = reinterpret_cast<const hd_lookup_result*>(1); count = 123;
    assert(!hd_lookup_run(lookup, "\xff", 16, 16, &results, &count) && !results && count == 0);
    hd_lookup_options invalid{}; invalid.frequency_order = 99;
    results = reinterpret_cast<const hd_lookup_result*>(1); count = 123;
    assert(!hd_lookup_run_with_options(lookup, "a", 16, 16, &invalid, &results, &count) && !results && count == 0);
    hd_lookup_free(lookup);
    hd_deinflector_free(deinflector);
    hd_query_free(query);
    std::filesystem::remove_all(root);
    std::cout << "Hoshi C API actual boundary regression PASS\n";
}
