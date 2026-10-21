#pragma once
#include <cstdint>
#include <string_view>
namespace as6::audio {
struct NativeMusicResource {std::int32_t id;std::string_view name;std::uint64_t bytes;std::uint32_t crc32;};
inline constexpr NativeMusicResource NativeMusicResources[]={
{590,"m_electro_1.wav",5815356ULL,0xf315f42fu},
{591,"m_electro_2.wav",5676092ULL,0x77ba38a6u},
{592,"m_electro_3.wav",5375036ULL,0x72265bccu},
{593,"m_electro_4.wav",5771324ULL,0x4ac3a39du},
{594,"m_electro_5.wav",4952124ULL,0xbf7ecb5fu},
{595,"m_electro_6.wav",4970556ULL,0xca2439c2u},
{596,"m_electro_7.wav",5670972ULL,0x59643c1bu},
{597,"m_electro_8.wav",5523516ULL,0x55da9490u},
{598,"m_electro_9.wav",4563004ULL,0x2d9472eeu},
{599,"m_electro_10.wav",5287996ULL,0xecdf6f59u},
{600,"m_electro_11.wav",4876348ULL,0x560e4d6fu},
{601,"m_electro_12.wav",5278780ULL,0xf5cba6b4u},
{602,"m_title.wav",2552892ULL,0xe2338d7au},
{603,"m_garage.wav",1238076ULL,0xc2f1b694u},
{606,"m_loading.wav",619580ULL,0x6d592971u},
};
inline const NativeMusicResource *nativeMusicResource(std::int32_t id) noexcept {for(const auto &item:NativeMusicResources)if(item.id==id)return &item;return nullptr;}
}
