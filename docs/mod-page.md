# Mod page text (GameBanana and other sites)

Paste the parts below into the site's fields. [BRACKETS] are things to fill in.

---

## Title

DELTARUNE Online: Co-op Multiplayer (Beta)

## Short description (one line)

Play all of DELTARUNE together online: each friend controls a party member, dodges with their own SOUL, and talks over proximity voice chat.

## Description

**DELTARUNE Online** lets 2 to 8 players play DELTARUNE (Chapters 1 to 5) together over the internet. Every player runs the game on their own PC and controls their own party member.

**Features**

- **Pick your party member.** Play as Kris, Susie, Ralsei or Noelle. You walk around as them, and in battle you choose their actions (FIGHT, ACT, MAGIC, ITEM, SPARE, DEFEND) and press for their attacks.
- **Everyone dodges.** In the bullet phase every player controls their own SOUL: red for Kris, purple for Susie, green for Ralsei, yellow for Noelle. Your grazes add to the shared TP bar.
- **Explore on your own.** Walk around, talk to NPCs and go to different rooms. Other players show up with name tags when you're in the same room.
- **Open-world battles.** Touch an enemy and you fight it with whoever is nearby, while everyone else keeps playing. Walk up to a fighting friend and press Z to jump in. The host can switch to "everyone gets pulled in" instead.
- **Shared story.** When someone starts a story cutscene, everyone is brought in and sees it together, and the text boxes turn their pages at the same time on every screen.
- **Shared progress.** Story, items, gold, equipment and HP stay in sync. The host's world is the shared one.
- **Proximity voice chat.** Hear players in the same room, quieter with distance. Push to talk (V) or open mic.
- **One-click installer with auto-updates.** The launcher installs everything and updates itself. Your Steam copy and normal saves are never touched.

**Requirements**

- Windows 10 or 11
- DELTARUNE on Steam (Chapters 1 to 5)
- Everyone needs the mod, at the same version (the launcher keeps it up to date)

**This download contains no DELTARUNE game files.** The mod patches a copy of your own game on your PC.

## Installation

1. Download **DELTARUNE Online.exe** and open it.
   Windows may say "Windows protected your PC" because the app isn't signed. Click **More info**, then **Run anyway**.
2. Click **INSTALL**. It finds your Steam copy of DELTARUNE, copies it to a separate folder and patches the copy (about 1 GB, a minute or two).
3. From then on, start the game from the **DELTARUNE Online** shortcut on your desktop. It checks for updates every time you open it.

To uninstall, open DELTARUNE Online and click **Uninstall** at the bottom.

Saves are kept separately in `%LOCALAPPDATA%\DELTARUNE_ONLINE`. To use your normal saves, copy the files from `%LOCALAPPDATA%\DELTARUNE` into that folder.

## How to play together

1. Everyone opens DELTARUNE Online, picks the **same chapter**, and starts or loads a file.
2. Press **F9** to open the multiplayer menu. Set your name and pick who you play as.
3. The host chooses **Host a game**.
4. Everyone else types the host's address into **Host address** and chooses **Join game**.

**Connecting over the internet:** the host needs **UDP port 26510** forwarded on their router. If you don't want to touch your router, everyone can install a free virtual network program like **Radmin VPN**, **ZeroTier** or **Tailscale**, join the same network, and use the host's address from that program instead.

## Controls

| Key | What it does |
|---|---|
| F9 | Multiplayer menu (host, join, settings, controls) |
| V | Push to talk |
| F8 | Go to the host (if you're stuck or want to catch up) |
| Shift+F8 | Host only: bring everyone to you |
| F7 | Stop all music and sounds (if the music gets out of step) |
| F6 | Noclip, your own game only (for softlocks) |

## Known issues (this is a beta)

- Story cutscene syncing has mostly been tested in Chapter 2. Scenes in other chapters, scenes with choices, and scenes that move between rooms may act up. F8 and the softlock tools in the F9 menu help if you get stuck.
- Cutscenes started by pressing Z on something only play for the player who did it (the story progress still syncs).
- Bosses with heavily scripted fights haven't all been played through in multiplayer.
- Bullet patterns can differ a little between players after the first hit.
- Platforming sections show everyone as Kris.
- If the host leaves, the session ends.

**Reporting a bug:** describe what happened and attach `multiplayer_log.txt` from `%LOCALAPPDATA%\DELTARUNE_ONLINE`.

## Credits

- **traebon**: DELTARUNE Online
- **AeEn123AI**: original DELTARUNE Multiplayer mod, which this is based on (GPL-3.0) [link]
- **UnderminersTeam**: UndertaleModTool, used to patch the game
- **Toby Fox**: DELTARUNE

Made with AI assistance (Claude Code). Free software under the GPL-3.0; source code: [link].

Unofficial fan project, not affiliated with Toby Fox or the DELTARUNE team.
