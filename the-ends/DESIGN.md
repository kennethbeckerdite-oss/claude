# Game Design Session 01

**Date:** May 8, 2026  
**Participants:** Kenneth + Claude (Opus)  
**Purpose:** Initial concept development for untitled top-down 2D roguelike shooter

-----

## Engine Decision

After evaluating s&box (Facepunch/Source 2), Unity, and GameMaker, **Godot 4** was selected.

**Reasons:**

- First-class 2D pipeline, not an afterthought
- Free and open source
- GDScript is approachable; transfers conceptually to Python
- Lightweight — runs on 2019 MacBook Pro i5
- Readable scene/node structure supports a non-coder + AI coder workflow
- Strong Steam export path

**Development environment:**

- Building on Mac (currently 2019 MBP i5, transitioning to M4 Mini in ~2 weeks)
- Mac-first, Windows export later
- Target platform: Steam (v1 no multiplayer)

-----

## Core Concept

An elite soldier is dropped into a hostile world. The hook is **reverse progression** — you start fully loaded with chosen abilities and have everything to lose over the course of a run.

> *"You chose everything but have everything to lose."*

- Top-down 2D shooter
- Futuristic setting
- 4–5 biomes
- Environmental/FromSoftware-style storytelling — narrative coded into discoverable objects, not cutscenes

-----

## Pre-Run: Contract & Loadout

### Contracts

- Before dropping in, player chooses from **3 contracts**
- Contracts are faction-based
- Contracts contribute objectives to the exfil gauge
- Faction passives: TBD (flagged as a later feature)

### Loadout

- **9 total power-ups** available in the game (unlocked/discovered over time)
- Player selects **3 power-ups** before each run
- Powers are independent but can complement each other in player-defined ways
- Over time players naturally gravitate toward a preferred main three

-----

## Core Loop

### Lives = Powers

- Each power-up functions as a life/heart
- Lose all HP while a power is active → lose that power permanently for the run
- Degradation path: **3 powers → 2 powers → 1 power → Knife**

### Knife / Rogue Mode

- Losing all powers triggers **Rogue Mode**
- Grants: 3 smoke bombs (consumable) + rechargeable invisibility
- Functions as a genre shift mid-run: from brawler to stealth survival
- Enemies that were manageable with powers become genuinely threatening
- Skilled players may be able to finish a run from this state

### Slot Machine (Recovery)

- Mid-run recovery mechanic only — not available at start
- Grants **2 random power-ups**
- Exists so a bad run never feels like a total wash
- Player can still exfil with something

-----

## Exfil & Gauge System

- Runs end when the player chooses to **exfil** (not a timer)
- A **gauge** must be filled before exfil is available
- Gauge fills via:
  - Contract objective completions
  - Kills
  - Exploration discoveries (hidden — e.g. finding an egg and returning it to the ship)
- **Bosses** are present and gate higher-tier upgrade progression
- Higher upgrade tiers require multiple boss kills to fill gauge

-----

## Progression & Upgrade Tree

### Base Upgrades

- Successfully exfil with a power-up → that power becomes upgradable
- Die → lose that run's upgrade progress on those powers
- Incentivizes finishing runs with all 3 powers intact

### Blend Modifier (Late-Game Unlock)

- Available at the top of the upgrade tree
- Forces player to commit to **3 specific, fully developed power paths**
- Makes those powers significantly stronger
- Trades flexibility for mastery

### Blend Type (TBD)

Needs the 9 power-ups defined before deciding. Three candidate models:

- **Fusion** — two powers combine into one slot, freeing a slot and creating a hybrid ability
- **Amplifier** — one dominant power, other two feed into it as satellite abilities
- **Set Bonus** — a hidden fourth ability that only activates when specific three are paired

-----

## Open Design Questions

- [ ] What are the 9 power-ups?
- [ ] What are the 4–5 biomes and how do they affect enemy behavior?
- [ ] What is the mission/narrative context for the soldier drop-in?
- [ ] How do faction passives work mechanically?
- [ ] Which blend model fits best once powers are defined?
- [ ] Does the knife/Rogue Mode have any upgrade path or is it always baseline?
- [ ] What is the game called?

-----

## Workflow Notes

- **Opus** handles: system design, game feel, mechanic architecture, "what and why"
- **Sonnet** handles: code generation, debugging, implementation, "how"
- Always give Sonnet a tight brief with relevant existing code and specific task
- Maintain a **game design bible** (this doc) as single source of truth — paste relevant sections into Sonnet at the start of each coding session

-----

*Session 01 — concept phase complete. Next step: download Godot 4, orient to editor, begin player movement prototype.*
