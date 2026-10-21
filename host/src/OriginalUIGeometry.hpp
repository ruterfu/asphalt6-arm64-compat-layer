#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <vector>

namespace as6_original_ui {
struct P { double x = 0, y = 0; };
struct V { double x = 0, y = 0, z = 0; };
inline V operator+(V a, V b) { return {a.x+b.x,a.y+b.y,a.z+b.z}; }
inline V operator-(V a, V b) { return {a.x-b.x,a.y-b.y,a.z-b.z}; }
inline V operator*(V a, double k) { return {a.x*k,a.y*k,a.z*k}; }
inline double dot(V a,V b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
inline V cross(V a,V b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
inline bool finite(P p) { return std::isfinite(p.x)&&std::isfinite(p.y); }
// Original FlashFX six-float layout: x=a*x+b*y+tx, y=c*x+d*y+ty.
struct M { double a=1,b=0,tx=0,c=0,d=1,ty=0; };
inline M matrix(const float *f) { return {f[0],f[1],f[2],f[3],f[4],f[5]}; }
inline P apply(M m,P p) { return {m.a*p.x+m.b*p.y+m.tx,m.c*p.x+m.d*p.y+m.ty}; }
inline P vector(M m,P p) { return {m.a*p.x+m.b*p.y,m.c*p.x+m.d*p.y}; }
inline bool inverse(M m,M &o) {
    const double z=m.a*m.d-m.b*m.c;
    if (!std::isfinite(z)||std::abs(z)<1e-12) return false;
    o={m.d/z,-m.b/z,0,-m.c/z,m.a/z,0};
    const auto t=vector(o,{m.tx,m.ty});o.tx=-t.x;o.ty=-t.y;return true;
}
inline M multiply(M a,M b) {
    const P x=vector(a,{b.a,b.c}),y=vector(a,{b.b,b.d}),t=apply(a,{b.tx,b.ty});
    return {x.x,y.x,t.x,x.y,y.y,t.y};
}
struct Rect { double x0=0,y0=0,x1=0,y1=0; };
inline std::array<P,4> corners(Rect r) { return {{{r.x0,r.y0},{r.x1,r.y0},{r.x1,r.y1},{r.x0,r.y1}}}; }
inline bool bounds(const std::array<P,4>&p,Rect &r) {
    r={p[0].x,p[0].y,p[0].x,p[0].y};
    for(auto q:p){if(!finite(q))return false;r.x0=std::min(r.x0,q.x);r.y0=std::min(r.y0,q.y);r.x1=std::max(r.x1,q.x);r.y1=std::max(r.y1,q.y);}return true;
}
inline bool correction(Rect b,Rect s,P &d,double tolerance=.05) {
    if(b.x1-b.x0>s.x1-s.x0+tolerance||b.y1-b.y0>s.y1-s.y0+tolerance)return false;
    d={b.x0<s.x0?s.x0-b.x0:(b.x1>s.x1?s.x1-b.x1:0),b.y0<s.y0?s.y0-b.y0:(b.y1>s.y1?s.y1-b.y1:0)};return finite(d);
}
struct H {
    double m[9]={1,0,0,0,1,0,0,0,1};
    bool project(P p,P &o) const {
        const double w=m[6]*p.x+m[7]*p.y+m[8];
        if(!std::isfinite(w)||std::abs(w)<1e-10)return false;
        o={(m[0]*p.x+m[1]*p.y+m[2])/w,(m[3]*p.x+m[4]*p.y+m[5])/w};return finite(o);
    }
};
inline bool homography(const std::array<P,4>&src,const std::array<P,4>&dst,H &out) {
    double a[8][9]{};
    for(unsigned i=0;i<4;++i){const auto p=src[i],q=dst[i];if(!finite(p)||!finite(q))return false;
        double *x=a[i*2],*y=a[i*2+1];x[0]=p.x;x[1]=p.y;x[2]=1;x[6]=-q.x*p.x;x[7]=-q.x*p.y;x[8]=q.x;
        y[3]=p.x;y[4]=p.y;y[5]=1;y[6]=-q.y*p.x;y[7]=-q.y*p.y;y[8]=q.y;}
    for(unsigned k=0;k<8;++k){unsigned pivot=k;for(unsigned r=k+1;r<8;++r)if(std::abs(a[r][k])>std::abs(a[pivot][k]))pivot=r;
        if(std::abs(a[pivot][k])<1e-12)return false;for(unsigned c=0;c<9;++c)std::swap(a[k][c],a[pivot][c]);
        const double z=a[k][k];for(unsigned c=k;c<9;++c)a[k][c]/=z;
        for(unsigned r=0;r<8;++r)if(r!=k){const double f=a[r][k];for(unsigned c=k;c<9;++c)a[r][c]-=f*a[k][c];}}
    for(unsigned i=0;i<8;++i)out.m[i]=a[i][8];out.m[8]=1;return true;
}
// A,C and B,C are the two live edges supplied by original acd30. Flags3
// use the original swap-then-horizontal-flip convention (17d5bc..17d5d8).
inline bool rayToUV(V start,V end,V a,V b,V c,P &uv) {
    const V u=a-c,v=b-c,n=cross(u,v),direction=end-start;
    const double den=dot(n,direction);if(std::abs(den)<1e-12)return false;
    const double t=dot(n,c-start)/den;if(!std::isfinite(t))return false;
    const V p=start+direction*t-c;
    const double uu=dot(u,u),uvv=dot(u,v),vv=dot(v,v),z=uu*vv-uvv*uvv;
    if(std::abs(z)<1e-12)return false;
    const double x=(dot(p,u)*vv-dot(p,v)*uvv)/z,y=(dot(p,v)*uu-dot(p,u)*uvv)/z;
    uv={1-y,x};return finite(uv);
}
// Apply one uniform stage transform to independent UI branches with different
// original parents. Child layout, original skew/rotation and hit shapes follow.
inline bool uniformLocalInStage(M base,M parent,P from,P to,double scale,M &out) {
    if(!finite(from)||!finite(to)||!std::isfinite(scale)||scale<=0||scale>1.000001)return false;
    M inv;if(!inverse(parent,inv))return false;
    const auto origin=apply(parent,{base.tx,base.ty});
    const auto desired=apply(inv,{to.x+scale*(origin.x-from.x),to.y+scale*(origin.y-from.y)});
    out={base.a*scale,base.b*scale,desired.x,base.c*scale,base.d*scale,desired.y};return finite(desired);
}
inline bool stripUniformLocal(M base,M installed,M current,double scale,M &out) {
    if(current.a!=installed.a||current.b!=installed.b||current.c!=installed.c||current.d!=installed.d||!std::isfinite(scale)||scale<=0)return false;
    out=base;out.tx+=(current.tx-installed.tx)/scale;out.ty+=(current.ty-installed.ty)/scale;
    return std::isfinite(out.tx)&&std::isfinite(out.ty);
}
inline bool affineLocalInStage(M base,M parent,M stageAffine,M &out,M &prefix) {
    M inv;if(!inverse(parent,inv))return false;
    prefix=multiply(multiply(inv,stageAffine),parent);
    out=multiply(prefix,base);
    return std::isfinite(out.a)&&std::isfinite(out.b)&&std::isfinite(out.tx)&&std::isfinite(out.c)&&std::isfinite(out.d)&&std::isfinite(out.ty);
}
inline bool stripKnownAffineLocal(M base,M installed,M current,M prefix,M &out) {
    if(current.a!=installed.a||current.b!=installed.b||current.c!=installed.c||current.d!=installed.d)return false;
    M inv;if(!inverse(prefix,inv))return false;
    const P delta=vector(inv,{current.tx-installed.tx,current.ty-installed.ty});
    out=base;out.tx+=delta.x;out.ty+=delta.y;
    return std::isfinite(out.tx)&&std::isfinite(out.ty);
}
struct UniformFrame {
    double scale=1;
    P from{},to{};
    Rect before{},after{};
};
inline bool fitUniformFrame(const H &stageToHost,const H &hostToStage,Rect frame,Rect safe,Rect window,UniformFrame &out) {
    if(frame.x1<=frame.x0||frame.y1<=frame.y0||safe.x1<=safe.x0||safe.y1<=safe.y0||window.x1<=window.x0||window.y1<=window.y0)return false;
    const auto original=corners(frame);std::array<P,4> projected{};
    for(unsigned i=0;i<4;++i)if(!stageToHost.project(original[i],projected[i]))return false;
    if(!bounds(projected,out.before))return false;
    // Choose a center in both the real plane quad and the screen safe rect.
    // This avoids moving UI outside a finite RTT plane merely to center it.
    std::vector<P> poly(projected.begin(),projected.end());
    for(unsigned edge=0;edge<4&&!poly.empty();++edge){std::vector<P> clipped;
        const auto distance=[&](P p){switch(edge){case 0:return p.x-safe.x0;case 1:return safe.x1-p.x;case 2:return p.y-safe.y0;default:return safe.y1-p.y;}};
        for(unsigned i=0;i<poly.size();++i){const P a=poly[i],b=poly[(i+1)%poly.size()];const double da=distance(a),db=distance(b);const bool ia=da>=0,ib=db>=0;
            if(ia)clipped.push_back(a);if(ia!=ib){const double t=da/(da-db);clipped.push_back({a.x+(b.x-a.x)*t,a.y+(b.y-a.y)*t});}}
        poly=std::move(clipped);
    }
    if(poly.empty())return false;
    P targetHost{(safe.x0+safe.x1)*.5,(safe.y0+safe.y1)*.5},targetStage;
    const auto inFrame=[&](P p){return p.x>=frame.x0&&p.x<=frame.x1&&p.y>=frame.y0&&p.y<=frame.y1;};
    if(!hostToStage.project(targetHost,targetStage)||!inFrame(targetStage)){
        targetHost={};for(P p:poly){targetHost.x+=p.x;targetHost.y+=p.y;}targetHost.x/=poly.size();targetHost.y/=poly.size();
        if(!hostToStage.project(targetHost,targetStage)||!inFrame(targetStage))return false;
    }
    out.from={(frame.x0+frame.x1)*.5,(frame.y0+frame.y1)*.5};
    const double width=frame.x1-frame.x0,height=frame.y1-frame.y0;
    const double start=std::min({1.,(safe.x1-safe.x0)/(window.x1-window.x0),(safe.y1-safe.y0)/(window.y1-window.y0)});
    const auto candidate=[&](double s,P &center,Rect &box){
        center={std::clamp(targetStage.x,frame.x0+s*width*.5,frame.x1-s*width*.5),std::clamp(targetStage.y,frame.y0+s*height*.5,frame.y1-s*height*.5)};
        std::array<P,4>p{};for(unsigned i=0;i<4;++i)if(!stageToHost.project({center.x+s*(original[i].x-out.from.x),center.y+s*(original[i].y-out.from.y)},p[i]))return false;
        if(!bounds(p,box))return false;
        return box.x0>=safe.x0-.1&&box.x1<=safe.x1+.1&&box.y0>=safe.y0-.1&&box.y1<=safe.y1+.1;
    };
    if(start<=0)return false;
    if(candidate(start,out.to,out.after)){out.scale=start;return true;}
    double lo=0,hi=start;P center;Rect box;
    for(unsigned i=0;i<24;++i){const double s=(lo+hi)*.5;if(candidate(s,center,box)){lo=s;out.to=center;out.after=box;}else hi=s;}
    if(lo<.01)return false;out.scale=lo;return true;
}
}
