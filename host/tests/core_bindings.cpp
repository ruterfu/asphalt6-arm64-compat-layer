#include "GuestNativeCore.hpp"
#include "GuestLocalClassRegistry.hpp"
#include "NativeDataBundle.hpp"
#include <cassert>
#include <cstdio>
#include <cstring>

using namespace as6native;
using namespace as6aot;
static unsigned checks;
#define CHECK(x) do{++checks;assert(x);}while(0)
static Status Tiny(Context &,bool,std::uint32_t,bool){return Returned;}
static NativeFunction lookup(std::uint32_t pc,bool thumb){return pc==0x1000&&!thumb?Tiny:nullptr;}
static const NativeModule modules[]={{0x2000,0x2000,lookup}};
static const NativeProgram program(modules,1,layout::Size,layout::pc);
static std::uint64_t byte(std::uint64_t value,std::uint8_t b){return (value^b)*1099511628211ULL;}
static void number(std::uint64_t &value,std::uint64_t input,unsigned size){for(unsigned n=0;n<size;++n)value=byte(value,std::uint8_t(input>>(8*n)));}
static void text(std::uint64_t &value,const char *s){do{value=byte(value,std::uint8_t(*s));}while(*s++);}

static void actual_static_data() {
    std::size_t bridge_count=0;const auto *bridges=AS6GeneratedBridges(&bridge_count);
    const auto *data=AS6GeneratedDataManifest();
    Provider p{ProviderVersion,&program,bridges,bridge_count,data,0x1000,"actual-data-binding-unit-only"};
    Core core(p);std::string error;CHECK(core.initialize(error));CHECK(!core.ready());
    auto writer=core.binding_writer();auto invalid=core.binding_writer();
    CHECK(!invalid.set(0,1,error));
    unsigned static_count=0,readonly_count=0;
    std::uint64_t metadata_hash=14695981039346656037ULL,payload_hash=metadata_hash;
    for(std::size_t i=0;i<data->binding_count;++i) {
        const auto &b=data->bindings[i];std::uint32_t value=0xfeedface;
        number(metadata_hash,b.address,4);number(metadata_hash,std::uint32_t(b.kind),4);number(metadata_hash,b.static_value,4);number(metadata_hash,b.original_word,4);
        number(metadata_hash,std::uint64_t(b.addend),8);number(metadata_hash,b.source_begin,8);number(metadata_hash,b.source_count,8);text(metadata_hash,b.symbol);
        CHECK(!core.read(b.address,&value,4)&&value==0xfeedface);
        CHECK(!core.write(b.address,&value,4));
        if(b.kind==BindingKind::StaticValue) {
            CHECK(!writer.set(i,b.static_value^1u,error));
            CHECK(writer.set(i,b.static_value,error));
            CHECK(core.read(b.address,&value,4)&&value==b.static_value);
            CHECK(!writer.set(i,b.static_value,error));
            if(b.address<0x700000){CHECK(!core.write(b.address,&value,4));++readonly_count;}
            ++static_count;
        } else if(b.kind==BindingKind::Unavailable) CHECK(!writer.set(i,123,error));
    }
    for(std::size_t i=0;i<data->binding_source_count;++i){const auto &s=data->binding_sources[i];number(metadata_hash,s.address,4);text(metadata_hash,s.symbol);number(metadata_hash,std::uint64_t(s.addend),8);number(metadata_hash,std::uint32_t(s.ordinal),4);number(metadata_hash,s.flags,4);number(metadata_hash,s.stream_kind,4);}
    std::uint8_t loaded[4096];
    for(std::size_t i=0;i<data->span_count;++i){const auto &s=data->spans[i];if(s.kind==DataKind::ZeroFill)continue;
        for(std::size_t n=0;n<s.length;){auto count=std::min<std::size_t>(4096,s.length-n);CHECK(core.read(s.address+unsigned(n),loaded,count)&&!std::memcmp(loaded,s.bytes+n,count));for(std::size_t j=0;j<count;++j)payload_hash=byte(payload_hash,loaded[j]);n+=count;}}
    CHECK(data->binding_count==8396&&data->binding_source_count==8408);
    CHECK(static_count==7142&&core.bound_count()==static_count&&readonly_count==1293);
    CHECK(!writer.finish(error)&&!core.ready());
    CHECK(!writer.set(data->binding_count,123,error));
    const auto *classes=core.section("__objc_classlist");CHECK(classes&&classes->size==172);
    std::vector<LocalClassRecord> records;
    auto text=[&](std::uint32_t at,std::size_t cap,std::string &out){out.clear();for(std::size_t i=0;i<cap;++i){char c=0;if(!core.read(at+unsigned(i),&c,1))return false;if(!c)return true;out.push_back(c);}return false;};
    CHECK(CollectLocalClasses(classes->address,classes->size,[&](std::uint32_t at,void *out,std::size_t n){return core.read(at,out,n);},text,records,error));
    CHECK(records.size()==43);
    for(const auto &r:records)CHECK(!r.name.empty()&&r.address&&r.ro&&r.isa);
    CHECK(!core.section("__objc_data")&&!core.section("__cfstring"));
    const std::pair<std::uint32_t,std::uint32_t> late_slots[]={
        {0x3e4974u,0x70b1c0u},{0x3e4b64u,0x70b1c0u},{0x3ec608u,0x717664u},
        {0x45e7a4u,0x717550u},{0x45e7a8u,0x70b1c0u},{0x4750f4u,0x70b1c0u},
        {0x5193a0u,0x70b1c0u},{0x564ba8u,0x70b1c0u}};
    for(auto slot:late_slots) {
        std::uint32_t value=0xdeadbeef;CHECK(core.read(slot.first,&value,4)&&value==slot.second);
        CHECK(!core.write(slot.first,&value,4)&&!core.ensure_dynamic(slot.first,4));
    }
    std::printf("{\"passed\":true,\"actual_static_bindings\":%u,\"readonly_static_bindings\":%u,\"actual_local_classes_before_super_binding\":%zu,\"binding_metadata_fnv64\":\"%016llx\",\"initial_payload_fnv64\":\"%016llx\",",static_count,readonly_count,records.size(),(unsigned long long)metadata_hash,(unsigned long long)payload_hash);
}

static void phase_and_metadata_guards() {
    const std::uint8_t seed[]={1,2,3,4};
    DataRegion region{0x8000,4096,1};DataSpan span{0x8000,4,seed,DataKind::ReadOnlyBytes};
    Section section{"__unit_data",0x8000,12};
    BindingSource sources[]={{0x8004,"_unit_a",0,1,0,1},{0x8008,"_unit_b",0,1,0,1}};
    DataBinding bindings[]={{0x8004,BindingKind::DataAddress,"_unit_a",0,0,0,0,1},{0x8008,BindingKind::DataAddress,"_unit_b",0,0,0,1,1}};
    DataManifest data{ProviderVersion,&region,1,&span,1,&section,1,nullptr,0,0x3ffef000,bindings,2,sources,2};
    Provider p{ProviderVersion,&program,nullptr,0,&data,0x1000,"binding-capability-unit"};
    Core core(p);std::string error;CHECK(core.initialize(error));auto writer=core.binding_writer();
    CHECK(!core.ready()&&!core.section("__unit_data"));
    CHECK(!writer.set(0,0,error)&&!writer.finish(error));
    CHECK(writer.set(0,0x20000000,error)&&!core.section("__unit_data"));
    CHECK(writer.set(1,0x20000004,error)&&core.section("__unit_data"));
    CHECK(writer.finish(error)&&core.ready());
    std::uint32_t value=0;CHECK(core.read(0x8004,&value,4)&&value==0x20000000);
    CHECK(!core.write(0x8004,&value,4));
    CHECK(!writer.set(1,99,error)&&!writer.finish(error));
    Core replay(p);CHECK(replay.initialize(error)&&!replay.initialize(error));
    auto old=p;old.version=1;Core old_core(old);CHECK(!old_core.initialize(error));
    auto overlap=bindings[0];overlap.address=0x8000;auto overlapping_source=sources[0];overlapping_source.address=0x8000;
    auto bad_data=data;bad_data.bindings=&overlap;bad_data.binding_count=1;bad_data.binding_sources=&overlapping_source;bad_data.binding_source_count=1;
    auto bad=p;bad.data=&bad_data;Core bad_core(bad);CHECK(!bad_core.initialize(error)&&error.find("overlap")!=std::string::npos);
    auto malformed_source=sources[0];malformed_source.addend=8;
    bad_data=data;bad_data.binding_sources=&malformed_source;bad_data.binding_source_count=1;bad_data.binding_count=1;
    bad.data=&bad_data;Core source_core(bad);CHECK(!source_core.initialize(error));
    std::vector<LocalClassRecord> staged{{0x7770,0,0,0,"unchanged"}};
    CHECK(!CollectLocalClasses(0x8000,4,[&](std::uint32_t at,void *out,std::size_t n){return core.read(at,out,n);},[](std::uint32_t,std::size_t,std::string&){return false;},staged,error));
    CHECK(staged.size()==1&&staged[0].name=="unchanged");
    CHECK(!CollectLocalClasses(0xfffffffcu,8,[](std::uint32_t,void*,std::size_t){return true;},[](std::uint32_t,std::size_t,std::string&){return true;},staged,error));
    std::printf("\"capability_phase_and_tamper_checks\":%u,\"game_execution\":false}\n",checks);
}
int main(){actual_static_data();phase_and_metadata_guards();}
