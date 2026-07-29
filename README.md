
# ImmortalizerJailed

Keep your apps running in the foreground indefinitely, even if they are in the background!

**For iOS 14 and above, [download here](https://github.com/sergealagon/ImmortalizerJailed/releases/)**

_This is the jailed version of the tweak [Immortalizer](https://github.com/sergealagon/Immortalizer) that can be injected on any IPA, **without the need of jailbreak or TrollStore!**_

### Installation
1. No need for jailbreak or TrollStore, so all you have to do is inject the dylib to an IPA you want this to work.
2. You may use any tools like **Sideloadly**, **E-Sign**, or even **TrollFools** to inject the dylib to an app.

### Details
- Just like the tweak, it can make apps stay in the foreground, however, you need to inject this onto the app you want to immortalize. 
- A **floating movable button** toggles Immortalizer. It docks to either edge after a few seconds; tap the docked handle to expand it again.
- Long-press the button to open the live diagnostics log. The button is grey while off, green when the foreground hook is healthy, and red when the hook is unavailable or appears not to be holding.
- The silent-audio keep-alive automatically recovers from interruptions, route changes, and playback stalls. When disabled, it restores the host app's previous audio-session configuration when it can do so without overwriting a newer host configuration.
- Just like the TrollStore version, there's no way to force notifications. It's a bit tricky to force notifications to show, especially for apps that render their own notification UI when their app is opened (e.g. WhatsApp).

### Building
The included GitHub Actions workflow builds on pushes, pull requests, or manual dispatch and uploads `ZImmortalizerJailed.dylib`. The Theos checkout is pinned in the workflow so toolchain changes are deliberate rather than implicit.

# License
    Copyright (C) 2025  Serge Alagon

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>. 

