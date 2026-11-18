#include "SourceWeightFeatures.cpp" // Same translation unit tests private palette tie ordering.
#include <fstream>
#include <iostream>
using namespace aidoku::source;
int main(int argc,char**argv) {
    try {
        if(argc==2&&std::string(argv[1])=="--palette") {
            int count;while(std::cin>>count) {
                std::map<int,int> counts;std::vector<int> order;
                for(int j=0;j<count;++j){int value;std::cin>>value;counts[j]=value;order.push_back(j);}
                paletteArgsort(order,counts);for(int j:order)std::cout<<j<<' ';std::cout<<'\n';
            }
            return 0;
        }
        if(argc!=3)throw std::invalid_argument("input/output paths required");
        std::ifstream in(argv[1],std::ios::binary);in.exceptions(std::ios::failbit|std::ios::badbit);
        auto read=[&](void*p,size_t n){in.read(static_cast<char*>(p),n);};
        int dims[3];read(dims,sizeof dims);double spec[5];read(spec,sizeof spec);
        cv::Mat rgb(dims[0],dims[1],CV_8UC3),alpha(dims[0],dims[1],dims[2]?CV_64F:CV_32F),own(dims[0],dims[1],CV_8U);
        read(rgb.data,rgb.total()*3);read(alpha.data,alpha.total()*alpha.elemSize());read(own.data,own.total());
        Vec shared(358);read(shared.data(),shared.size()*8);
        cv::Rect2d b(spec[0],spec[1],spec[2],spec[3]);double prior=spec[4];Vec output;
        append(output,weightEstimatorExtra40(rgb,b,prior));append(output,weightStroke55(rgb,b,prior));
        append(output,weightGrouped144(rgb,b,prior));auto direct=weightDirect7(rgb,b,prior);append(output,direct.features);
        WeightFillStyle style{{24,80,210},{240,230,220},true,1.7};
        append(output,weightFill71V1(alpha,b,prior,own,style));
        append(output,composeWeightRaw597(rgb,b,prior,Vec(shared.begin(),shared.begin()+156),
                                        Vec(shared.begin()+156,shared.begin()+212),Vec(shared.begin()+212,shared.end())));
        // Invalid inputs must fail without partially accepting substitute fields.
        auto rejects=[](auto fn){try{fn();}catch(const std::invalid_argument&){return;}throw std::logic_error("Invalid input accepted");};
        rejects([&]{composeWeightRaw597(rgb,b,prior,Vec(155),Vec(56),Vec(146));});
        rejects([&]{weightStroke55(rgb,b,0);});
        rejects([&]{weightDirect7(rgb,cv::Rect2d(rgb.cols+1,0,1,1),prior);});
        rejects([&]{weightFill71V1(alpha,b,prior,cv::Mat(),style);});
        Vec invalid(156);invalid[0]=NAN;rejects([&]{composeWeightRaw597(rgb,b,prior,invalid,Vec(56),Vec(146));});
        std::ofstream out(argv[2],std::ios::binary);out.write(reinterpret_cast<const char*>(output.data()),output.size()*8);
        std::cout<<direct.mask<<'\n';
    } catch(const std::exception&e){std::cerr<<e.what()<<'\n';return 1;}
}
