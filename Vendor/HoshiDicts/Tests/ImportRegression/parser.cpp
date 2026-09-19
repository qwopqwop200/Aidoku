#include "json/yomitan_parser.hpp"
#include <cassert>
#include <iostream>
#include <vector>
int main() {
 std::vector<Term> terms;
 std::string valid = R"([["猫","ねこ","","",1.5,["cat"],1,""]])";
 assert(yomitan_parser::parse_term_bank(valid,terms));
 assert(terms.size()==1 && terms[0].expression=="猫" && terms[0].score==1.5);
 for(size_t i=0;i<valid.size();++i) {
  std::vector<Term> incomplete;
  assert(!yomitan_parser::parse_term_bank(std::string_view(valid.data(),i),incomplete));
 }
 for (std::string_view s : {"0","2147483647","-2147483648",R"({"frequency":3,"displayValue":"3 times"})",R"({"reading":"ねこ","frequency":{"value":5,"displayValue":"five"}})"}) {
  ParsedFrequency f;
  assert(yomitan_parser::parse_frequency(s,f));
 }
 for (std::string_view s : {"2147483648","-2147483649","1e500","{","[]"}) {
  ParsedFrequency f;
  assert(!yomitan_parser::parse_frequency(s,f));
 }
 std::vector<Term> empty;
 assert(!yomitan_parser::parse_term_bank("[[]]",empty));
 std::vector<Term> trailing;
 assert(!yomitan_parser::parse_term_bank(valid+"garbage",trailing));
 std::cout << "glaze bounded view truncation/integer variants PASS\n";
}
