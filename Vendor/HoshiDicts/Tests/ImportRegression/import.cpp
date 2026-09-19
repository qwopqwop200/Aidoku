#include "hoshidicts/importer.hpp"
#include <iostream>
int main(int argc,char**argv) {
 if(argc!=3)return 2;
 auto result=dictionary_importer::import(argv[1],argv[2],true);
 std::cout << "success=" << result.success << " error=" << result.error << '\n';
 return result.success ? 0:1;
}
