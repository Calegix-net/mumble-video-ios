# Installing on an iPhone (sideloading)

There is no App Store or TestFlight build yet. Each release has an unsigned `MumbleVideo.ipa`. A
sideloading tool signs it with your own Apple ID and installs it. A free Apple ID is enough.

1. **Get the IPA.** Download `MumbleVideo.ipa` from the latest release:
   <https://github.com/Calegix-net/mumble-video-ios/releases/latest>. Builds of `main` also appear as the
   `MumbleVideo-ipa` artifact on each run under the Actions tab. You need to be signed in to GitHub to
   download artifacts.
2. **Install Sideloadly** from <https://sideloadly.io> (Windows or macOS). On Windows it also needs Apple's
   iTunes and iCloud **from apple.com, not the Microsoft Store**. Sideloadly links to both.
3. **Connect the iPhone** by USB, unlock it, and tap **Trust** when it asks.
4. **Turn on Developer Mode** (iOS 16 and later): Settings › Privacy & Security › Developer Mode, then
   restart the phone when asked. The switch appears only after a sideloaded app is installed once, so
   do step 5, then come back here if the app won't open.
5. **Sideload.** Drag `MumbleVideo.ipa` into Sideloadly, enter your Apple ID, then press **Start**. Leave
   the advanced options at their defaults.
6. **Trust yourself as a developer.** The first time, go to Settings › General › VPN & Device Management.
   Tap your Apple ID, then tap **Trust**.
7. Open **Mumble Video**. Add a server with **+**, or open a `mumble://host:port` link.

## Things to know

- **It expires after 7 days** with a free Apple ID. Run Sideloadly again with the same IPA to refresh.
  Your saved servers are kept. Sideloadly can refresh automatically while the phone is on the same Wi-Fi.
  A paid developer account makes it last a year.
- A free Apple ID can have **3 sideloaded apps** at once. Mumble Video counts as 2 because of its
  screen-sharing extension.
- **Screen sharing** starts from the Video tab (**Share screen**), or from Control Center: long-press
  Screen Recording and pick Mumble Video. It needs the App Group that Sideloadly registers for you. If
  the Video tab says screen sharing needs a signed build, the App Group was not registered. In that case,
  sideload again with Sideloadly's **Advanced options › Signing mode** at its default (Apple ID sideload).
- Allow **microphone, camera and local network** access when asked. They can be changed later in
  Settings › Mumble Video.

## Updating

Install the newer IPA the same way. It replaces the old one in place.
