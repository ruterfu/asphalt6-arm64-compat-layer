#include "SystemZlibCore.hpp"
#include <zlib.h>
#include <algorithm>
#include <array>
#include <cstdlib>
#include <cstring>
#include <map>
#include <new>
#include <string>
#include <vector>

namespace as6port {
namespace {
bool interval(std::uint32_t at,std::size_t bytes) {
    return !bytes || (at>=4096 && std::uint64_t(bytes)<=0x100000000ULL-at);
}
struct FreeBytes { void operator()(Bytef *p)const{std::free(p);} };
using Bytes=std::unique_ptr<Bytef,FreeBytes>;
}
struct SystemZlib::Impl {
    struct Stream {
        Impl &owner;
        z_stream host{};
        ZStream32 guest{};
        std::map<void *,std::uint32_t> allocations;
        std::uint32_t identity=0;
        std::string messageText;
        std::uint32_t messageAddress=0;
        bool active=false,initialized=false,callback_stopped=false,memory_fault=false;
        explicit Stream(Impl &value):owner(value){}
        bool stopped(){return callback_stopped || owner.services.stopped(owner.services.owner);}
        std::uint32_t guest_allocate(uInt items,uInt size) {
            if(stopped()) {callback_stopped=true;return 0;}
            if(guest.zalloc==DefaultZalloc)
                return owner.services.heap_alloc(owner.services.owner,std::size_t(items)*size);
            const std::uint32_t args[]={guest.opaque,items,size};
            const auto result=owner.services.call(owner.services.owner,guest.zalloc,args,3);
            if(owner.services.stopped(owner.services.owner))callback_stopped=true;
            return callback_stopped?0:result;
        }
        void guest_free(std::uint32_t pointer) {
            if(!pointer)return;
            if(stopped()){callback_stopped=true;return;}
            if(guest.zfree==DefaultZfree) {
                if(!owner.services.heap_free(owner.services.owner,pointer))callback_stopped=true;
            } else {
                const std::uint32_t args[]={guest.opaque,pointer};
                owner.services.call(owner.services.owner,guest.zfree,args,2);
                if(owner.services.stopped(owner.services.owner))callback_stopped=true;
            }
        }
        static voidpf allocate(voidpf raw,uInt items,uInt size) noexcept {
            auto &s=*static_cast<Stream *>(raw);
            const std::uint64_t count=std::uint64_t(items)*size;
            if(count>UINT32_MAX || count>SIZE_MAX)return nullptr;
            std::uint32_t guest=0;
            void *host=nullptr;
            try {
                guest=s.guest_allocate(items,size);
                if(!guest)return nullptr;
                if(!s.owner.probe(guest,std::size_t(count))){
                    s.memory_fault=true;s.guest_free(guest);return nullptr;
                }
                host=std::calloc(1,count?std::size_t(count):1);
                if(!host){s.guest_free(guest);return nullptr;}
                s.allocations.emplace(host,guest);
                if(!s.identity)s.identity=guest;
                return host;
            } catch(...) {
                s.callback_stopped=true;
                std::free(host);
                return nullptr;
            }
        }
        static void release(voidpf raw,voidpf host) noexcept {
            if(!host)return;
            auto &s=*static_cast<Stream *>(raw);
            const auto found=s.allocations.find(host);
            if(found==s.allocations.end()){s.callback_stopped=true;return;}
            const auto guest=found->second;s.allocations.erase(found);
            try{s.guest_free(guest);}catch(...){s.callback_stopped=true;}
            std::free(host);
        }
        ~Stream(){
            // Cleanup runs with the owning VM alive/locked, before VM destroy.
            if(initialized){active=true;::inflateEnd(&host);initialized=false;}
            while(!allocations.empty())release(this,allocations.begin()->first);
        }
    };
    GuestServices services;
    std::map<std::uint32_t,std::unique_ptr<Stream>> streams;
    explicit Impl(GuestServices value):services(value){}
    bool read(std::uint32_t at,void *out,std::size_t n) {
        return interval(at,n)&&(!n||services.read(services.owner,at,out,n));
    }
    bool write(std::uint32_t at,const void *in,std::size_t n) {
        return interval(at,n)&&(!n||services.write(services.owner,at,in,n));
    }
    bool probe(std::uint32_t at,std::size_t n) {
        return interval(at,n)&&(!n||services.probe(services.owner,at,n));
    }
    bool publish(std::uint32_t address,Stream &s,ZStream32 value) {
        value.total_in=std::uint32_t(s.host.total_in);
        value.total_out=std::uint32_t(s.host.total_out);
        value.adler=std::uint32_t(s.host.adler);
        value.data_type=s.host.data_type;
        value.reserved=std::uint32_t(s.host.reserved);
        value.state=s.initialized?s.identity:0;
        if(s.host.msg){
            if(!s.messageAddress||s.messageText!=s.host.msg){
                s.messageAddress=services.message(services.owner,s.host.msg);
                if(s.messageAddress)s.messageText=s.host.msg;
            }
            value.msg=s.messageAddress;
            if(!value.msg)return false;
        } else value.msg=0;
        return write(address,&value,sizeof(value));
    }
    ZResult invoke(ZOperation operation,std::uint32_t address,int argument,
                   std::uint32_t version,std::uint32_t size) {
        const bool initializing=operation==ZOperation::Init||operation==ZOperation::Init2;
        // The original Init2 checks version/sizeof before touching z_stream.
        if(initializing){
            char major=0;
            if(!version||size!=56)return {Z_VERSION_ERROR,false,false};
            if(!read(version,&major,1))return {Z_VERSION_ERROR,true,false};
            if(major!='1')return {Z_VERSION_ERROR,false,false};
        }
        if(!address)return {Z_STREAM_ERROR,false,false};
        ZStream32 guest{};
        if(!read(address,&guest,sizeof(guest)))return {Z_STREAM_ERROR,true,false};
        auto found=streams.find(address);
        if(found!=streams.end()&&found->second->active)return {Z_STREAM_ERROR,false,false};
        if(initializing){
            // Preserve the original armv7 public version/sizeof contract; the
            // host call separately supplies its own version and host sizeof.
            if(found!=streams.end())return {Z_STREAM_ERROR,false,false};
            auto stream=std::make_unique<Stream>(*this);
            stream->guest=guest;
            if(!stream->guest.zalloc){stream->guest.zalloc=DefaultZalloc;stream->guest.opaque=0;}
            if(!stream->guest.zfree)stream->guest.zfree=DefaultZfree;
            Stream *s=stream.get();streams.emplace(address,std::move(stream));
            s->host.zalloc=Stream::allocate;s->host.zfree=Stream::release;s->host.opaque=s;
            s->active=true;
            const auto result=::inflateInit2_(&s->host,operation==ZOperation::Init?15:argument,
                                             ZLIB_VERSION,int(sizeof(z_stream)));
            s->initialized=result==Z_OK;
            const bool stopped=s->stopped();
            const bool wrote=stopped?true:publish(address,*s,s->guest);
            const bool memoryFault=s->memory_fault||!wrote;s->active=false;
            if(result!=Z_OK||!wrote||stopped)streams.erase(address);
            return {result,memoryFault,stopped};
        }
        if(found==streams.end())return {Z_STREAM_ERROR,false,false};
        Stream &s=*found->second;
        if(!s.initialized||guest.state!=s.identity||guest.zalloc!=s.guest.zalloc||
           guest.zfree!=s.guest.zfree||guest.opaque!=s.guest.opaque)
            return {Z_STREAM_ERROR,false,false};
        s.active=true;
        struct ActiveScope {Stream *s;~ActiveScope(){if(s)s->active=false;}} active{&s};
        if(operation==ZOperation::Reset){
            const int result=::inflateReset(&s.host);
            const bool wrote=publish(address,s,guest);
            return {result,!wrote,s.stopped()};
        }
        if(operation==ZOperation::End){
            const int result=::inflateEnd(&s.host);s.initialized=false;
            const bool stopped=s.stopped();
            const bool wrote=stopped?true:publish(address,s,guest);
            s.active=false;active.s=nullptr;streams.erase(address);
            return {result,!wrote,stopped};
        }
        if(!guest.next_out||(!guest.next_in&&guest.avail_in))return {Z_STREAM_ERROR,false,s.stopped()};
        // Preflight the complete guest intervals before allocating host copies.
        // Output write permissions are checked by the complete bulk write at
        // commit; neither host zlib nor its allocator sees a guest pointer.
        if(!probe(guest.next_in,guest.avail_in)||!probe(guest.next_out,guest.avail_out))
            return {Z_STREAM_ERROR,true,s.stopped()};
        Bytes input(static_cast<Bytef *>(std::malloc(guest.avail_in?guest.avail_in:1)));
        Bytes output(static_cast<Bytef *>(std::malloc(guest.avail_out?guest.avail_out:1)));
        if(!input||!output)return {Z_MEM_ERROR,false,s.stopped()};
        if(!read(guest.next_in,input.get(),guest.avail_in))return {Z_STREAM_ERROR,true,s.stopped()};
        s.host.next_in=guest.next_in?input.get():nullptr;s.host.avail_in=guest.avail_in;
        s.host.next_out=output.get();s.host.avail_out=guest.avail_out;
        // armv7 uLong is 32 bits. The application-visible counters may wrap or
        // be reset by its caller, independently of host uLong's 64-bit width.
        s.host.total_in=guest.total_in;s.host.total_out=guest.total_out;
        const int result=::inflate(&s.host,argument);
        const auto consumed=guest.avail_in-s.host.avail_in;
        const auto produced=guest.avail_out-s.host.avail_out;
        if(s.stopped()){
            s.host.next_in=nullptr;s.host.next_out=nullptr;
            return {result,s.memory_fault,true};
        }
        const bool copied=write(guest.next_out,output.get(),produced);
        // No pointer into the temporary copies survives this bridge.
        s.host.next_in=nullptr;s.host.next_out=nullptr;
        guest.next_in+=consumed;guest.avail_in=s.host.avail_in;
        guest.next_out+=produced;guest.avail_out=s.host.avail_out;
        const bool wrote=copied&&publish(address,s,guest);
        return {result,!wrote||s.memory_fault,s.stopped()};
    }
};
SystemZlib::SystemZlib(GuestServices services):impl_(new Impl(services)){}
SystemZlib::~SystemZlib()=default;
ZResult SystemZlib::invoke(ZOperation op,std::uint32_t stream,int argument,
                           std::uint32_t version,std::uint32_t size) {
    try {return impl_->invoke(op,stream,argument,version,size);}
    catch(const std::bad_alloc &){return {Z_MEM_ERROR,false,impl_->services.stopped(impl_->services.owner)};}
}
std::size_t SystemZlib::live_streams()const {
    std::size_t count=0;for(const auto &entry:impl_->streams)if(entry.second->initialized)++count;
    return count;
}
}
