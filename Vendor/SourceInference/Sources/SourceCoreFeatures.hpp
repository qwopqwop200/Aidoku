#pragma once
#include "SourceFeatureMath.hpp"
namespace aidoku { namespace source {
Vec nativeFeatures(const cv::Mat&rgb,const cv::Rect2d&bbox,double prior);
Vec maskedFeatures(const cv::Mat&rgb,const cv::Rect2d&bbox,double prior,const cv::Mat&ownership);
Vec cadenceFeatures(const cv::Mat&rgb,const cv::Rect2d&bbox,double prior,const cv::Mat&ownership,double characterCount);
Vec colorBodies(const cv::Mat&rgb,const cv::Rect2d&bbox,double prior,const cv::Mat&ownership);
struct ComponentDescriptor {Vec features;double size;cv::Rect bounds;std::vector<unsigned char> packedShape;};
std::vector<ComponentDescriptor> extractComponents(const cv::Mat&rgb,const cv::Rect2d&bbox,double prior,const cv::Mat&ownership);
}}
