extends RefCounted
## Shared constants. Tweak the game's feel here.

const VERSION := "0.6"          # online players must run the same version

const CELL := 16               # px between terrain grid nodes
const GW := 81                 # grid nodes across
const GH := 46                 # grid nodes down
const W := (GW - 1) * CELL     # 1280 px
const H := (GH - 1) * CELL     # 720 px

const GRAVITY := 95.0          # px/s^2, always pulls down
const THRUST := 240.0          # px/s^2 from the rear booster
const TURN := 4.0              # rad/s
const DRAG := 0.12             # fraction of speed lost per second
const MAX_SPEED := 420.0

const BULLET_SPEED := 520.0
const BULLET_LIFE := 2.4
const BULLET_GRAV := 0.35      # bullets feel a bit of gravity too
const FIRE_CD := 0.45

const LAND_SPEED := 120.0      # touch down slower than this, upright, feet first = safe landing
const LAND_ANGLE := 0.55       # rad from upright
const SPAWN_SHIELD := 1.0

const ROUND_LIMIT := 90.0      # seconds before a round is called a draw

# Ship colors players pick from (no two active players may share one).
const PNAMES := ["RED", "ORANGE", "YELLOW", "GREEN", "CYAN", "BLUE", "PURPLE", "PINK", "WHITE"]
const PALETTE := [Color("ff4d5e"), Color("ff9f1c"), Color("ffd23f"), Color("5ee87d"), Color("3ff0e0"),
		Color("4da6ff"), Color("b07cff"), Color("ff7ac8"), Color("f2f2f2")]

const TEAM_NAMES := ["TEAM A", "TEAM B"]
const TEAM_COLORS := [Color("ffb04a"), Color("6ec3ff")]

# ---- power-ups
const PU_EVERY := 7.0          # average seconds between spawns
const PU_MAX := 2              # max on the map at once
const PU_LIFE := 16.0          # seconds before an uncollected one fades
const PU_KINDS := ["shield", "triple", "rapid", "feather", "bounce", "missile"]
const PU := {
	"shield": {"name": "SHIELD", "icon": "S", "col": Color("7fe7ff")},          # blocks one hit
	"triple": {"name": "TRIPLE SHOT", "icon": "3", "col": Color("ffd23f"), "time": 8.0},
	"rapid": {"name": "RAPID FIRE", "icon": "R", "col": Color("ff6b6b"), "time": 6.0},
	"feather": {"name": "LOW GRAVITY", "icon": "G", "col": Color("b8f5a0"), "time": 9.0},
	"bounce": {"name": "RICOCHET", "icon": "B", "col": Color("ff9ff3"), "time": 8.0},
	"missile": {"name": "HOMING MISSILES", "icon": "M", "col": Color("ffa94d")},  # next 2 shots
}
const MISSILE_SPEED := 300.0
const MISSILE_TURN := 3.0      # rad/s
const MISSILE_LIFE := 5.0
