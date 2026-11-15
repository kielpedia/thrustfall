# Thrustfall

A gravity spaceship brawler for up to 4 players, made in Godot 4.7.

Your ship has one rear booster. Gravity always pulls you down, and touching rock blows you up unless you land gently, upright and feet first. Every map is randomly generated, and one shot kills.

- **Modes:** Rounds (last ship standing), Stock (lives and respawns), Timed (most kills; crashes cost a point)
- **Teams** with optional friendly fire, **6 power-ups**, **10 ship hulls** with shape-accurate hitboxes
- **CPU pilots** to fill empty seats
- **Local play:** 4 players on one keyboard and/or gamepads
- **Online play:** host/join by address

## Controls

| Player | Thrust | Turn | Fire |
|---|---|---|---|
| P1 | W | A / D | S or Space |
| P2 | Up | Left / Right | Down or / |
| P3 | I | J / L | K or H |
| P4 | Num 8 | Num 4 / 6 | Num 5 or Num 0 |

Gamepad N controls player N: D-pad or stick to turn, A or RT to thrust, X, B or RB to fire.
In the menu, your turn keys change your color, thrust changes your ship and fire switches your team.

## Playing online with friends

Everyone needs **the same version** of the game; the game checks this when you join.

1. **One person hosts.** On the title screen, click **HOST ONLINE**. The screen then lists the addresses friends can use.
2. **Everyone else joins.** Type the host's address into the box next to **JOIN** and click it. Each friend gets a seat and picks their own color, ship and team. The host sets everything else and presses **LAUNCH**.

The game uses **UDP port 7777**. Friends who aren't on the same home network need one of these:

- **Tailscale (easiest, free).** Everyone installs [Tailscale](https://tailscale.com) and joins the host's tailnet; the host shares their machine with friends, or everyone signs into one shared account. Friends then join with the host's Tailscale address (it starts with `100.`). No router changes are needed.
- **Port forwarding.** The host forwards UDP port 7777 on their router to their PC. Friends join with the host's public IP, which you can find by searching "what is my ip".

When Windows Firewall asks about Thrustfall the first time you host, click **Allow**.

Online, each PC has one player, who uses the P1 keys or the first gamepad. The host's PC can still have extra local players, and CPUs fill any empty seats. If a friend drops mid-match, a CPU takes over their ship.

## Building the game to share

1. Open the project in Godot 4.7.2.
2. Go to **Editor → Manage Export Templates → Download and Install** (needed once).
3. Go to **Project → Export → Windows Desktop → Export Project**. This writes `build/Thrustfall.exe`, a single file with everything inside.
4. Send that `.exe` to friends, for example through Discord, Google Drive, or a GitHub Release on this repo.

## Developer tests

```
godot --headless --path . -- --autotest                          # map generator, hulls, every mode with 4 CPUs
godot --headless --path . -- --nethost                           # online test: host...
godot --headless --path . -- --netjoin 127.0.0.1 --lag 120       # ...and a guest with 120 ms fake lag
godot --path . -- --demo [--teams] [--stock|--timed]             # watch CPUs play
```
