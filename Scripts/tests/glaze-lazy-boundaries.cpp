// Focused BEVE lazy boundary regression. Root owns compilation/sanitizer runs.
// Example: clang++ -std=c++23 -fsanitize=address,undefined -fno-sanitize-recover=all
//   -I Vendor/HoshiDicts/external/glaze/include Scripts/tests/glaze-lazy-boundaries.cpp -o /tmp/glaze-lazy-boundaries
// Modes permit independent baseline reproductions: default, truncated, counts, valid.
#include <glaze/beve/lazy.hpp>

#include <array>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <string>
#include <string_view>

static void check(bool condition, const char* message)
{
   if (!condition) {
      std::fprintf(stderr, "%s\n", message);
      std::abort();
   }
}

template <class T, class View>
static void rejects(const View& view, const char* message)
{
   check(!view.template get<T>().has_value(), message);
}

static void default_views()
{
   glz::lazy_beve_view<> view;
   rejects<int>(view, "default view must reject get<int>");
   rejects<std::nullptr_t>(view, "default view must reject get<nullptr_t>");
   check(view.is_null() && !view.is_number() && view.empty(), "default queries remain safe");
   glz::lazy_beve_document<> empty;
   rejects<int>(empty.root(), "default document view must reject get<int>");
}

static void truncated_values()
{
   // Generic array declares two entries, but only the first null exists.
   std::array<char, 3> bytes{0x05, 0x08, 0x00};
   auto doc = glz::lazy_beve(bytes);
   check(doc.has_value(), "lazy construction intentionally validates only the root tag");
   rejects<std::nullptr_t>((*doc)[1], "missing array member must reject access");
   check((*doc)[0].get<std::nullptr_t>().has_value(), "complete prefix value remains readable");
   size_t visited = 0;
   for (const auto& value : doc->root()) {
      check(++visited <= 1, "iterator must stop at truncated array end");
      check(value.get<std::nullptr_t>().has_value(), "iteration returns only present null");
   }
   glz::lazy_beve_view<> at_end{&*doc, bytes.data() + bytes.size()};
   rejects<int>(at_end, "explicit end view must reject get");
   check(!at_end.is_number() && !at_end.is_array() && at_end.raw_beve().empty(), "end queries must not dereference");
   int into = 0;
   check(bool(at_end.read_into(into)), "end view must reject read_into");

   for (const auto& string_bytes : {std::string("\x02", 1), std::string("\x02\x01", 2),
                                   std::string("\x02\x10x", 3)}) {
      auto string_doc = glz::lazy_beve(string_bytes);
      check(string_doc.has_value(), "string tag accepted lazily");
      rejects<std::string>(string_doc->root(), "truncated string must reject string conversion");
      rejects<std::string_view>(string_doc->root(), "truncated string must reject view conversion");
   }

   std::array<char, 4> strings{0x3c, 0x08, 0x04, 'h'};
   auto string_array = glz::lazy_beve(strings);
   check(string_array.has_value(), "typed string array tag accepted");
   rejects<std::string>((*string_array)[1], "missing typed string must reject access");
   check(string_array->root().index().size() == 1, "typed string index retains only encoded member");

   std::array<char, 4> numbers{0x2c, 0x08, 0x2a, 0x00}; // signed 16-bit, count 2, one value
   auto number_array = glz::lazy_beve(numbers);
   check(number_array.has_value(), "typed number array tag accepted");
   rejects<int>((*number_array)[1], "missing typed number must reject access before pointer arithmetic");
   check(number_array->root().index().size() == 1, "typed number index retains only complete member");

   std::array<char, 4> object{0x03, 0x04, 0x04, 'k'}; // key exists, value tag is absent
   auto object_doc = glz::lazy_beve(object);
   check(object_doc.has_value(), "object tag accepted");
   check((*object_doc)["k"].has_error(), "key without value must not resolve");
   check(object_doc->root().index().empty(), "index must not expose missing object value");
   check(object_doc->root().begin() == object_doc->root().end(), "object iterator must stop before missing value");

   std::array<char, 4> number_key{0x2b, 0x04, 0x2a, 0x00}; // 16-bit numeric key, no value
   auto number_object = glz::lazy_beve(number_key);
   check(number_object.has_value(), "numeric object tag accepted");
   check(number_object->root().index().empty(), "numeric key needs a following value");
   check(number_object->root().begin() == number_object->root().end(), "numeric key iterator checks remaining bytes");
}

static void hostile_counts()
{
   // 62-bit maximum count cannot fit vector::max_size(), so baseline reserve
   // throws length_error before requesting memory. No huge allocation is needed.
   for (char tag : {char(0x05), char(0x03), char(0x0c), char(0x3c), char(0x1c)}) {
      std::array<char, 9> bytes{tag, char(0xff), char(0xff), char(0xff), char(0xff),
                               char(0xff), char(0xff), char(0xff), char(0xff)};
      auto doc = glz::lazy_beve(bytes);
      check(doc.has_value(), "container tag accepted lazily");
      try {
         check(doc->root().index().empty(), "count without payload must yield no index members");
      }
      catch (const std::exception&) {
         check(false, "untrusted encoded count must not reach vector reservation");
      }
   }
}

static void valid_values()
{
   std::array<char, 5> bytes{0x05, 0x0c, 0x00, 0x08, 0x18};
   auto doc = glz::lazy_beve(bytes);
   check(doc.has_value(), "valid generic array");
   auto index = doc->root().index();
   check(index.size() == 3 && index[0].get<std::nullptr_t>().has_value(), "valid generic null unchanged");
   check(index[1].get<bool>().value() == false && index[2].get<bool>().value() == true, "valid booleans unchanged");

   std::array<char, 8> object{0x03, 0x08, 0x04, 'a', 0x00, 0x04, 'b', 0x18};
   auto object_doc = glz::lazy_beve(object);
   check(object_doc.has_value(), "valid object");
   check((*object_doc)["b"].get<bool>().value(), "progressive lookup reads final key");
   check((*object_doc)["a"].get<std::nullptr_t>().has_value(), "lookup wraps to first key");
   check(object_doc->root().index().size() == 2, "valid object index unchanged");

   std::array<char, 4> numbers{0x0c, 0x08, 0x2a, char(0xfd)};
   auto numeric_doc = glz::lazy_beve(numbers);
   check(numeric_doc.has_value(), "valid numeric array");
   check((*numeric_doc)[0].get<int>().value() == 42 && (*numeric_doc)[1].get<int>().value() == -3,
         "numeric array direct values unchanged");
   auto numeric_index = numeric_doc->root().index();
   check(numeric_index.size() == 2 && numeric_index[1].get<int>().value() == -3, "numeric index unchanged");

   std::array<char, 8> strings{0x3c, 0x0c, 0x08, 'h', 'i', 0x00, 0x04, 'x'};
   auto string_doc = glz::lazy_beve(strings);
   check(string_doc.has_value(), "valid typed string array");
   check((*string_doc)[0].get<std::string>().value() == "hi" && (*string_doc)[1].get<std::string>().value().empty(),
         "typed strings including empty value unchanged");
   auto string_index = string_doc->root().index();
   check(string_index.size() == 3 && string_index[2].get<std::string_view>().value() == "x", "typed string index unchanged");

   std::array<char, 3> booleans{0x1c, 0x20, 0x55};
   auto bool_doc = glz::lazy_beve(booleans);
   check(bool_doc.has_value(), "valid packed booleans");
   auto bool_index = bool_doc->root().index();
   check(bool_index.empty() && bool_index.is_typed_array(), "packed booleans retain existing unsupported-index contract");
}

int main(int argc, char** argv)
{
   const std::string_view mode = argc > 1 ? argv[1] : "all";
   if (mode == "all" || mode == "default") default_views();
   if (mode == "all" || mode == "truncated") truncated_values();
   if (mode == "all" || mode == "counts") hostile_counts();
   if (mode == "all" || mode == "valid") valid_values();
   check(mode == "all" || mode == "default" || mode == "truncated" || mode == "counts" || mode == "valid", "unknown mode");
   std::puts("glaze lazy BEVE boundaries passed");
}
