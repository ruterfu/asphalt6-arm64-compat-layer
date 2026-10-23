#pragma once
// The device's screen class, decided once at startup from the screen's long
// to short side ratio and kept for the run:
//  Wide        about 2:1 and wider (full-screen iPhones): adapted, 2.2:1 art;
//  SixteenNine about 16:9 (home-button iPhones): adapted, 16:9 art;
//  Plain       anything else (iPads...): the 3:2 game is only scaled to fill
//              the screen, with no layout adaptation and the original art.
#ifdef __cplusplus
extern "C" {
#endif
enum { AS6ScreenPlain = 0, AS6ScreenSixteenNine = 1, AS6ScreenWide = 2 };
// Main thread, before the game starts. Later calls keep the first result.
int AS6ScreenProfileDetect(void);
// The cached result (Plain until detected).
int AS6ScreenProfile(void);
// Whether the 3D views show the wider screen's extra width (the wider
// perspective and the widened office monitor): an adapted screen with the HD
// pack installed. Otherwise the 3D image is only scaled; the 2D layout
// adaptation still follows the screen class.
int AS6ScreenShowsWideView(void);
#ifdef __cplusplus
}
#endif
