# Project Overview: Zero-G Tactical FPS

This project is a Godot prototype for a zero-gravity, six-degrees-of-freedom tactical FPS. The intended long-term game is a 5v5 competitive shooter built around defusal-style round structure, single elimination pressure, team coordination, precise shooting, body control, and zero-gravity movement.

The current prototype focus is not the full defusal mode. The main mode to prototype first is a single-elimination team deathmatch variant that uses the same core movement, combat, scoring, and teamplay ideas. This mode is meant to prove the main feel of the game before the larger defusal rules are built out.

The original concept in the design document described a zero-gravity battle room where two teams score by disabling the enemy team and/or entering the enemy gate. That concept has changed into a broader 5v5 defusal and single-elimination FPS, but the core identity remains the same: zero gravity, full 6DOF control, tactical teamwork, robot limb damage, momentum management, and objective pressure.

## High-Level Identity

The game is a tactical arena FPS in zero gravity.

Players do not simply run, jump, and strafe like a traditional shooter. They move through the arena by controlling momentum, orientation, body posture, pushes, impacts, and positioning. Because there is no gravity, there is no fixed up or down. A player can be sideways, upside down, spinning, drifting, bracing against a wall, or lining up a shot while moving through open space.

The central challenge is not only shooting accurately. Players must also understand where their body is, where their momentum is carrying them, which way they are oriented, which limbs are still usable, where their teammates are, and whether the team should fight, survive, reposition, or push the objective.

The game should feel tactical and deliberate, even though the movement can be physically dynamic. Every push, rotation, missed surface, destroyed limb, or gate attempt can matter.

## Intended Main Game Direction

The intended full game direction is a 5v5 FPS with:

- Defusal-style team structure.
- Single-elimination round pressure.
- Zero-gravity movement.
- Six degrees of freedom.
- Robot limb destruction instead of a normal health-bar-only model.
- Team objectives that require coordination.
- A main prototype mode based on single-elimination team deathmatch.

The full defusal mode is part of the game direction, but it is not the current priority. The current priority is to prototype the single-elimination TDM-style mode because it exercises the most important core systems: movement, shooting, robot limb damage, scoring, team coordination, and objective movement through the arena.

## Current Prototype Mode: Single-Elimination TDM With Gate Scoring

The mode currently being designed for prototyping is a 5v5 single-elimination team mode.

Each round is a tactical 5v5 fight. Players are expected to have one life or otherwise be removed from meaningful round participation once eliminated or fully disabled. The team must balance direct combat against objective movement.

There are two main scoring methods:

- Killing, eliminating, or fully neutralizing the enemy team is worth 2 points.
- Going through the enemy gate is worth 3 points.

The gate objective requires teamwork. A single player cannot complete it alone. The current requirement discussed is that one player must go through the enemy gate while another teammate holds it open. This makes the gate objective require at least two players acting together.

The original design document described the gate condition as at least two active, non-disabled players passing through the enemy gate. The updated direction discussed here changes the emphasis slightly: one player goes through, and another player holds the gate open. Both versions point toward the same design goal: gate scoring should require coordinated team action, not a solo rush.

The win condition is not fully decided yet. Two possible directions are currently open:

- First team to reach a target number of points wins.
- After a set number of rounds, the team with the most points wins.

No final point target, round count, or match length has been locked in yet.

## Teams

Matches are designed around two teams of five players.

- Team A has 5 players.
- Team B has 5 players.

All players begin each round inside or near their team's starting zone.

The game is meant to support team tactics rather than only individual duels. Players should need to think about where teammates are, how many teammates remain active, who can help with the gate, who can still move effectively, and whether the team has enough functional players to complete the objective.

## Round Structure

Each round is a tactical 5v5 battle.

The round can reward a team for:

- Eliminating or fully neutralizing the enemy team.
- Completing the enemy gate objective.
- Potentially accomplishing both in the same round.

In the original design document, both objectives could be completed in the same round. That allowed a maximum of 5 points in one round:

- 2 points for eliminating or fully neutralizing all enemies.
- 3 points for entering the enemy gate.
- 5 total points if both objectives are completed.

That scoring structure is still useful as a reference for the prototype unless changed later. The current discussion keeps the same point values: 2 points for killing, eliminating, or fully neutralizing the enemy team and 3 points for going through the enemy gate.

## Movement Model

The arena is in zero gravity.

Players do not move through traditional walking, running, or jumping as the primary movement model. Instead, movement is based on pushing off and interacting with physical surfaces and objects.

Players can push off:

- Walls.
- Floors.
- Ceilings.
- Obstacles.
- Other players.
- Arena structures.

Once a player pushes off, they continue moving in that direction until another force changes their momentum. This means players retain momentum and can drift through open space. If a player moves away from usable surfaces or teammates, they may become vulnerable or unable to easily redirect themselves.

Movement should reward planning. A player who uses a wall, obstacle, or teammate well can create a strong angle or reach the gate. A player who misjudges a push can drift into danger, lose access to surfaces, or become easy to shoot.

## Six Degrees Of Freedom

The game uses six degrees of freedom.

Players can move and rotate freely in three-dimensional space. There is no true up, down, floor, or ceiling once a player is in motion. Orientation is a core part of play.

Players must manage:

- Position: where they are in the arena.
- Orientation: which direction their body is facing.
- Momentum: where their body is moving.
- Rotation: whether they are stable, turning, or spinning.
- Body exposure: which limbs and body sections are visible to enemies.
- Readiness: whether they are positioned to shoot, brace, push, enter the gate, or help a teammate.

Good players should be able to use rotation and posture to aim, protect limbs, reduce their target profile, prepare for impacts, and line up pushes.

## Body Position And Posture

The original concept includes body position hotkeys. These allow players to quickly change posture in zero gravity.

Possible body positions include:

- Fetal position.
- Full upright position.
- Arms tucked.
- Legs tucked.
- Defensive curl.
- Wide stance.
- Gate-entry pose.
- Wall-brace pose.

The fetal position makes the player more compact. This can make the player a smaller target, but may limit visibility, aiming angles, or readiness.

The full upright position extends the body in the direction the player is currently oriented. This may help with aiming, pushing off surfaces, or passing through gates, but it also makes the player a larger target.

Other body positions may affect hitbox shape, movement control, combat options, gate entry, or bracing against surfaces. These posture ideas are part of the original design direction, but the exact implementation details are not final.

## Combat Model

The intended combat model centers on accurate shooting and destroying or removing robot body parts.

The original design document gave each player one weapon:

- Laser gun.

That is no longer the intended final direction. The current code may still contain a laser gun, but future design should treat that as prototype or legacy implementation detail. The intended direction is normal FPS weapons, probably supported by a buy menu.

Players are robots rather than people in suits. When limbs are hit, they should be damaged, destroyed, or shot off rather than merely disabled as suit sections.

The key combat idea is that players do not simply lose abstract health. Instead, their ability to participate is reduced based on what gets hit or removed. A player can lose movement options, aiming ability, bracing ability, gate ability, or full participation depending on the damaged body section.

This makes aiming at specific body parts tactically meaningful.

## Robot Limb Damage System

Every player is a robot with body sections and limbs that can be damaged or shot off.

When a robot body part is hit by weapon fire, that part may become damaged, destroyed, or physically removed depending on the final weapon and damage rules.

Destroyed or missing limbs cannot be used for:

- Pushing off walls.
- Stabilizing movement.
- Changing direction.
- Aiming, if the missing or destroyed limb is needed for weapon control.
- Certain body positions.

Examples adapted from the original concept:

- If a player's right robot arm is shot off or destroyed, that arm can no longer be used.
- If a player's left robot leg is shot off or destroyed, that leg can no longer be used.
- If both legs are destroyed, the player may still be able to use active arms.

This system is important because movement and combat are deeply connected. Losing a limb is not only a damage state; it changes what the player can physically do in the arena.

## Critical Hit Zones

The original design includes stronger effects for certain hit zones. These should be adapted to the robot-body direction rather than treated as suit damage.

Head hit:

- Immediately disables the player.
- Counts as an elimination for the round.

Chest hit:

- Immediately disables, destroys, or otherwise removes use of the player's legs.
- Does not remove use of the arms.
- Leaves the player able to aim, shoot, push off with arms, or assist teammates if their arms are still functional.

These rules make different shots valuable in different ways. A head hit removes a player immediately. A chest hit can severely limit movement while still leaving the target partly active.

## Elimination And Full Neutralization

A player is considered eliminated, destroyed, or fully neutralized if they can no longer meaningfully participate in the round.

A player can be eliminated if:

- They are hit in the head.
- Their robot body is fully disabled, destroyed, or otherwise unable to keep participating.
- They lose enough function that the rules define them as inactive.

An eliminated, destroyed, or fully neutralized player cannot score, assist in gate capture, or continue fighting.

This matters especially because the gate objective requires active teammates. Destroying or removing key robot limbs can be just as strategically important as killing an enemy outright if it prevents them from fighting, moving, holding the gate, or entering the gate.

## Gate Objective

Each team has a gate associated with its side of the arena. The enemy gate is the objective.

The gate objective is worth 3 points.

The current discussed prototype requirement is:

- One active player must go through the enemy gate.
- Another active teammate must hold the gate open.
- This requires at least two players coordinating.

The original design document requirement was:

- At least two active, non-disabled players from the same team must pass through the enemy gate.
- Disabled or eliminated players do not count.
- A single player entering the gate does not score.

Both forms should be understood as expressing the same current design priority: the gate is a coordinated objective that cannot be completed by one player alone. Future implementation should clarify whether the exact rule is "two players pass through" or "one player passes while another holds the gate open."

## Scoring

The currently discussed scoring values are:

| Objective | Points |
| --- | ---: |
| Kill, eliminate, or fully neutralize the enemy team | 2 |
| Complete the enemy gate objective | 3 |

The original design allows both objectives to be scored in the same round, for a maximum of 5 points in a round.

The match win condition is undecided:

- It may be first to a target number of points.
- It may be most points after a fixed number of rounds.

Until the win condition is finalized, AI agents working on the project should treat the point values as known and the match ending rule as unresolved.

## Strategy And Player Decision-Making

The game rewards both combat skill and movement skill.

Players must think about:

- Which limbs to protect.
- Which enemies or robot limbs to disable, destroy, or remove first.
- Whether to fight or rush the gate.
- How to use walls and obstacles for movement.
- How to rotate while drifting.
- How to avoid becoming stranded in open space.
- How to help teammates move or recover.
- When to sacrifice positioning for a shot.
- When to destroy key limbs instead of fully eliminating enemies.
- Whether enough active teammates remain to attempt the gate.
- Whether an enemy is still dangerous even after losing some limb function.

Because players cannot freely move in open air, positioning is extremely important. A player drifting away from surfaces or teammates may become vulnerable. A player with missing or destroyed limbs may still be dangerous if they can aim or help with the objective.

The gate creates an important tactical split: teams can win value through fighting, but the higher-value objective requires coordinated movement and survival.

## Prototype Priorities

The current prototype should focus on proving the systems needed for the single-elimination TDM/gate mode.

The most important systems are:

- 5v5 team structure.
- Zero-gravity movement.
- Six-degrees-of-freedom body control.
- Shooting.
- Robot limb damage, destruction, and removal.
- Elimination, destruction, and full-neutralization rules.
- Gate objective behavior.
- Round scoring.
- A match win condition once the point or round target is chosen.

The defusal-style mode is part of the larger direction, but the prototype mode should come first because it tests the core game identity without requiring every defusal-specific rule to exist yet.

## Known Unresolved Design Questions

The following items are intentionally unresolved based on the current description:

- Whether matches end by first team to a point target or by highest score after a set number of rounds.
- The exact target score if using first-to-points.
- The exact number of rounds if using fixed-round scoring.
- Whether both objectives can always be scored in one round in the updated prototype.
- Whether the final gate rule is two players passing through or one player passing while another holds it open.
- The exact implementation details for body posture hotkeys.
- The exact rule for when partial robot limb damage becomes full elimination beyond the examples given.
- The exact relationship between the future defusal mode and the prototype single-elimination TDM mode.

AI agents should not invent answers to these questions. They should preserve them as design decisions to be made later unless the user provides more direction.

## Guidance For Future AI Agents

When working on this project, understand it as a zero-gravity tactical FPS first.

Do not treat it as a normal grounded shooter with a zero-gravity visual theme. The core of the game is the relationship between movement, body orientation, momentum, team objectives, and limb function.

Do not assume a standard health-bar combat model. The intended design uses robot body-part damage and limb loss, where hits change what a player can physically do.

Do not assume the full defusal mode is the immediate implementation target. The current priority is the single-elimination TDM-style prototype with gate scoring.

Do not finalize unresolved rules without user direction. If implementation work needs a temporary assumption, keep it narrow, document it clearly, and avoid presenting it as final design.

The game should be understood as a tactical team sport in zero gravity: combat matters, but so do body control, positioning, teammate coordination, and objective timing.
