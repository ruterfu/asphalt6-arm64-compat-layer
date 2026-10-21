#pragma once
#include <cstdint>
#include <set>
#include <string>
#include <vector>

namespace as6native {
struct LocalClassRecord {
    std::uint32_t address,isa,ro,methods;
    std::string name;
};
// Collect first, commit second. Failed reads never become zero class fields.
template<class Read,class CString>
bool CollectLocalClasses(std::uint32_t list,std::uint32_t size,Read read,CString string,
                         std::vector<LocalClassRecord> &output,std::string &error) {
    if(!size&&!list){output.clear();return true;}
    if(!list||!size||(list&3)||(size&3)||size>1024*1024||std::uint64_t(list)+size>0x100000000ULL){error="invalid local class list";return false;}
    std::vector<LocalClassRecord> staged;
    std::set<std::uint32_t> addresses;std::set<std::string> names;
    for(std::uint32_t offset=0;offset<size;offset+=4) {
        LocalClassRecord record{};std::uint32_t name=0;
        if(!read(list+offset,&record.address,4)||record.address<4096||record.address>0xffffffe0u||(record.address&3)||
           !read(record.address+16,&record.ro,4)||record.ro<4096||record.ro>0xffffffe0u||(record.ro&3)||
           !read(record.ro+16,&name,4)||!name||!string(name,128,record.name)||record.name.empty()||
           !read(record.address,&record.isa,4)||!record.isa||(record.isa&3)||
           !read(record.ro+20,&record.methods,4)) {error="local class registry requires unavailable class/ro/name bytes";return false;}
        if(!addresses.insert(record.address).second||!names.insert(record.name).second){error="duplicate local class identity/name";return false;}
        staged.push_back(std::move(record));
    }
    output=std::move(staged);return true;
}
}
