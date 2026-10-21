#include "MusicRandomSelection.hpp"
#include <algorithm>
#include <stdexcept>

namespace as6::audio {
SoundId chooseOriginalRandomMusic(SoundId group, MusicRandomState &state) {
    if (group!=590) return -1;
    if (state.recentCount>state.recent.size())
        throw std::invalid_argument("Music random history exceeds three entries");

    auto seed=state.seed;
    for (;;) {
        // Two original uint32 transitions per candidate; use all high16 bits.
        seed=seed*1664525u+1013904223u;
        seed=seed*1664525u+1013904223u;
        const auto selected=SoundId(590u+((seed>>16)%12u));
        bool recent=false;
        for (std::uint32_t i=0;i<state.recentCount;++i)
            if (state.recent[i]==selected) { recent=true;break; }
        if (recent) continue;

        state.seed=seed;
        for (auto i=std::min(state.recentCount,2u);i;--i)
            state.recent[i]=state.recent[i-1];
        state.recent[0]=selected;
        state.recentCount=std::min(state.recentCount+1u,3u);
        return selected;
    }
}
} // namespace as6::audio
