#include "hash/hash.hpp"
#include "hash/bloom.hpp"
#include "zip/zip.hpp"
#include <libdeflate.h>
#include <xxh3.h>
#include <cassert>
#include <cstring>
#include <fstream>
#include <random>
#include <iostream>
#include <unistd.h>

template<class T> void put(std::vector<uint8_t>& b,size_t offset,T value){assert(offset+sizeof(T)<=b.size());std::memcpy(b.data()+offset,&value,sizeof(T));}
void save(const std::filesystem::path& p,const std::vector<uint8_t>& b){std::ofstream f(p,std::ios::binary);f.write((const char*)b.data(),b.size());}
std::vector<uint8_t> archive(bool compressed, std::string content="dictionary payload"){
 std::string name="index.json";
 std::vector<uint8_t> payload(content.begin(),content.end());
 if(compressed){auto*c=libdeflate_alloc_compressor(6);assert(c);payload.resize(libdeflate_deflate_compress_bound(c,content.size()));auto n=libdeflate_deflate_compress(c,content.data(),content.size(),payload.data(),payload.size());assert(n);payload.resize(n);libdeflate_free_compressor(c);}
 size_t cd=30+name.size()+payload.size(),end=cd+46+name.size();std::vector<uint8_t>b(end+22);
 auto crc=libdeflate_crc32(0,content.data(),content.size());
 put<uint32_t>(b,0,0x04034b50);put<uint16_t>(b,8,compressed?8:0);put<uint32_t>(b,14,crc);put<uint32_t>(b,18,payload.size());put<uint32_t>(b,22,content.size());put<uint16_t>(b,26,name.size());
 std::memcpy(b.data()+30,name.data(),name.size());std::memcpy(b.data()+30+name.size(),payload.data(),payload.size());
 put<uint32_t>(b,cd,0x02014b50);put<uint16_t>(b,cd+10,compressed?8:0);put<uint32_t>(b,cd+16,crc);put<uint32_t>(b,cd+20,payload.size());put<uint32_t>(b,cd+24,content.size());put<uint16_t>(b,cd+28,name.size());std::memcpy(b.data()+cd+46,name.data(),name.size());
 put<uint32_t>(b,end,0x06054b50);put<uint16_t>(b,end+8,1);put<uint16_t>(b,end+10,1);put<uint32_t>(b,end+12,46+name.size());put<uint32_t>(b,end+16,cd);return b;
}
int main(){
 const auto root=std::filesystem::temp_directory_path()/("aidoku-hoshi-storage-"+std::to_string(getpid()));std::filesystem::create_directory(root);
 hash::linear table;hash::bloom bloom;assert(table("before load")==0);assert(!bloom.contains(1));
 for(size_t n=0;n<4;++n){std::vector<uint8_t>b(n);assert(!table.load(b.data(),b.size()));}
 for(size_t n=0;n<16;++n){std::vector<uint8_t>b(n);assert(!bloom.load(b.data(),b.size()));}
 std::vector<uint8_t> zero(4);assert(!table.load(zero.data(),zero.size()));
 std::vector<uint8_t> full(4+16*16);put<uint32_t>(full,0,16);for(int i=0;i<16;i++){put<uint64_t>(full,4+i*16,1);put<uint64_t>(full,12+i*16,9);}assert(table.load(full.data(),full.size()));assert(table("missing") == 0);
 const auto h=XXH3_64bits("entry",5);table.build_to_file({{h,42}},root/"hash");hash::bloom::build_to_file({h},root/"bloom");auto hm=memory::map_rd(root/"hash"),bm=memory::map_rd(root/"bloom");assert(table.load(hm.data,hm.size));assert(bloom.load(bm.data,bm.size));table.set_bloom(&bloom);assert(table("entry")==42);assert(table("other")==0);memory::unmap(hm);memory::unmap(bm);
 std::mt19937_64 rng(92831);for(int i=0;i<20000;i++){std::vector<uint8_t>b(rng()%512+1);for(auto&x:b)x=rng();hash::linear t;hash::bloom f;if(t.load(b.data()+1,b.size()-1))(void)t("random");if(f.load(b.data()+1,b.size()-1))(void)f.contains(rng());}
 for(size_t length:{0u,65536u,65537u,150000u,524288u}){std::string large(length,'x');save(root/"large",archive(true,large));Zip z;assert(z.open(root/"large"));assert(z.read(0)==large);auto media=z.read_media(0);assert(media&&std::string(media->blob.begin(),media->blob.end())==large);}
 size_t checks=20000;
 for(bool compressed:{false,true}){auto good=archive(compressed);save(root/"zip",good);Zip z;assert(z.open(root/"zip"));assert(z.find("index.json")==0);assert(z.read(0)=="dictionary payload");auto media=z.read_media(0);assert(media&&std::string(media->blob.begin(),media->blob.end())=="dictionary payload");
 for(size_t n=0;n<good.size();++n){std::vector<uint8_t>b(good.begin(),good.begin()+n);save(root/"bad",b);assert(!z.open(root/"bad"));assert(z.entries.empty());checks++;}
 assert(z.open(root/"zip"));bool rejected=false;try{z.read(-1);}catch(const std::out_of_range&){rejected=true;}assert(rejected);
 auto cd=good.size()-22-(46+10);auto bad=good;
 if(compressed){put<uint32_t>(bad,cd+24,UINT32_MAX-1);save(root/"bad",bad);assert(z.open(root/"bad"));rejected=false;try{z.read(0);}catch(const std::runtime_error&){rejected=true;}assert(rejected);assert(!z.read_media(0));bad=good;}put<uint32_t>(bad,cd+42,UINT32_MAX-5);save(root/"bad",bad);assert(!z.open(root/"bad"));
 bad=good;put<uint16_t>(bad,cd+28,65535);save(root/"bad",bad);assert(!z.open(root/"bad"));
 bad=good;put<uint32_t>(bad,cd+16,0);save(root/"bad",bad);assert(z.open(root/"bad"));rejected=false;try{z.read(0);}catch(const std::runtime_error&){rejected=true;}assert(rejected);assert(!z.read_media(0));
 for(int i=0;i<1000;i++){bad=good;bad[rng()%bad.size()]=rng();save(root/"bad",bad);if(z.open(root/"bad")){for(size_t j=0;j<z.entries.size();j++){try{z.read(j);z.read_media(j);}catch(const std::exception&){}}}checks++;}
 }
 std::filesystem::remove_all(root);std::cout<<"Hoshi storage ASAN/UBSAN PASS checks="<<checks<<"\n";
}
