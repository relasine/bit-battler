//
//  EnemiesConstants.swift
//  Bit Battler Watch App
//

import CoreGraphics
import Foundation

// MARK: - Wave roll (`resetEnemies` uses `Int.random(in: 0..<EnemyWaveRoll.allCases.count)`)

enum EnemyWaveRoll: Int, CaseIterable {
    case primarySlot = 0
    case troll = 1
    case slime = 2
    case cyclops = 3
}

// MARK: - Sprite asset names per wave variant

struct EnemySpriteNames: Equatable {
    let idle: String
    let attack: String
    let damage: String
    /// Death strip shown by `EnemyDeathView` (asset catalog name).
    let death: String
}

// MARK: - Resolved wave (roll + room tier for primary slot / slime color)

/// Fully resolved enemy wave for combat, rendering, and accessibility.
enum EnemyWaveProfile: Equatable {
    case goblinPrimary
    case orcPrimary
    case troll
    case slimeGreen
    case slimeBlue
    case cyclops

    static func resolve(isSlimeWave: Bool, isTrollWave: Bool, isCyclopsWave: Bool, roomNumber: Int) -> EnemyWaveProfile {
        #if DEBUG
        let flagCount = [isSlimeWave, isTrollWave, isCyclopsWave].filter(\.self).count
        assert(flagCount <= 1, "EnemyWaveProfile.resolve: at most one wave-type flag should be true (got \(flagCount))")
        #endif
        if isCyclopsWave { return .cyclops }
        if isTrollWave { return .troll }
        if isSlimeWave { return roomNumber >= EnemiesConstants.slimeBlueMinRoomNumber ? .slimeBlue : .slimeGreen }
        return roomNumber >= EnemiesConstants.orcMinRoomNumber ? .orcPrimary : .goblinPrimary
    }

    var enemyCount: Int {
        switch self {
        case .goblinPrimary, .orcPrimary: return 3
        case .troll: return 2
        case .slimeGreen, .slimeBlue: return 4
        case .cyclops: return 1
        }
    }

    var hitsToKill: Int {
        switch self {
        case .cyclops: return EnemiesConstants.cyclopsHitsToKill
        case .slimeGreen: return EnemiesConstants.greenSlimeHitsToKill
        case .slimeBlue: return EnemiesConstants.blueSlimeHitsToKill
        case .troll: return EnemiesConstants.trollHitsToKill
        case .goblinPrimary: return EnemiesConstants.goblinHitsToKill
        case .orcPrimary: return EnemiesConstants.orcHitsToKill
        }
    }

    /// Chance each enemy's attack actually hits the rogue (`0...1`).
    var enemyHitChance: Double {
        switch self {
        case .slimeGreen: return EnemiesConstants.slimeHitChance
        case .slimeBlue: return EnemiesConstants.blueSlimeHitChance
        case .troll: return EnemiesConstants.trollHitChance
        case .cyclops: return EnemiesConstants.cyclopsHitChance
        case .goblinPrimary: return EnemiesConstants.goblinHitChance
        case .orcPrimary: return EnemiesConstants.orcHitChance
        }
    }

    var spriteNames: EnemySpriteNames {
        switch self {
        case .goblinPrimary:
            return EnemySpriteNames(idle: "GoblinIdle", attack: "GoblinAttack", damage: "GoblinDamage", death: "GoblinDie")
        case .orcPrimary:
            return EnemySpriteNames(idle: "OrcIdle", attack: "OrcAttack", damage: "OrcDamage", death: "OrcDie")
        case .troll:
            return EnemySpriteNames(idle: "TrollIdle", attack: "TrollAttack", damage: "TrollDamage", death: "TrollDie")
        case .slimeGreen:
            return EnemySpriteNames(idle: "SlimeIdle", attack: "SlimeAttack", damage: "SlimeDamage", death: "SlimeDead")
        case .slimeBlue:
            return EnemySpriteNames(idle: "BlueSlimeIdle", attack: "BlueSlimeAttack", damage: "BlueSlimeDamage", death: "BlueSlimeDie")
        case .cyclops:
            return EnemySpriteNames(idle: "CyclopsIdle", attack: "CyclopsAttack", damage: "CyclopsDamage", death: "CyclopsDead")
        }
    }

    /// Frame count for the death strip passed to `EnemyDeathView`.
    var deathStripFrameCount: Int {
        switch self {
        case .goblinPrimary: return EnemiesConstants.goblinDieFrameCount
        case .orcPrimary: return EnemiesConstants.orcDieFrameCount
        case .troll: return EnemiesConstants.trollDieFrameCount
        case .slimeGreen, .slimeBlue: return EnemiesConstants.slimeDieFrameCount
        case .cyclops: return EnemiesConstants.cyclopsDieFrameCount
        }
    }

    /// Total wall-clock duration for the death animation (matches prior tuning).
    var deathAnimationDuration: Double {
        switch self {
        case .cyclops:
            return Double(EnemiesConstants.cyclopsDieFrameCount) * EnemiesConstants.deathStripFrameDuration
        case .slimeGreen, .slimeBlue:
            return Double(EnemiesConstants.slimeDieFrameCount) * EnemiesConstants.deathStripFrameDuration
        case .goblinPrimary:
            return Double(EnemiesConstants.goblinDieFrameCount) * EnemiesConstants.deathStripFrameDuration
        case .orcPrimary, .troll:
            return GameConstants.deathAnimationDuration
        }
    }

    /// Horizontal tweak for cyclops attack alignment vs rogue.
    var attackOffsetXAdjustment: CGFloat {
        switch self {
        case .cyclops: return EnemiesConstants.cyclopsAttackOffsetXAdjustment
        default: return 0
        }
    }

    var usesPrimarySlotIdleStartFrames: Bool {
        switch self {
        case .goblinPrimary, .orcPrimary: return true
        default: return false
        }
    }

    func position(index: Int, enemyCount: Int) -> (x: CGFloat, y: CGFloat) {
        switch self {
        case .cyclops:
            return EnemiesConstants.cyclopsPosition
        case .slimeGreen, .slimeBlue:
            let i = max(0, min(index, EnemiesConstants.slimePositions.count - 1))
            return EnemiesConstants.slimePositions[i]
        case .troll:
            let i = max(0, min(index, EnemiesConstants.trollPositions.count - 1))
            return EnemiesConstants.trollPositions[i]
        case .goblinPrimary, .orcPrimary:
            let i = max(0, min(index, EnemiesConstants.primaryEnemySlotPositions.count - 1))
            return EnemiesConstants.primaryEnemySlotPosition(index: i, enemyCount: enemyCount)
        }
    }

    func accessibilityLabel(enemyIndex: Int) -> String {
        switch self {
        case .cyclops: return "Cyclops"
        case .slimeGreen: return "Slime \(enemyIndex + 1)"
        case .slimeBlue: return "Blue slime \(enemyIndex + 1)"
        case .troll: return "Troll \(enemyIndex + 1)"
        case .goblinPrimary: return "Goblin \(enemyIndex + 1)"
        case .orcPrimary: return "Orc \(enemyIndex + 1)"
        }
    }
}

// MARK: - Numeric / layout constants

enum EnemiesConstants {
    /// Primary slot uses goblins below this room, orcs at/above (when roll is primary).
    static let orcMinRoomNumber = 10
    /// Slime wave switches to blue slime assets and tougher HP at/above this room.
    static let slimeBlueMinRoomNumber = 10

    // MARK: Hits to kill (one unit per tap; crits add extra elsewhere)

    static let goblinHitsToKill = 3
    static let orcHitsToKill = 4
    static let greenSlimeHitsToKill = 2
    static let blueSlimeHitsToKill = 3
    static let trollHitsToKill = 5
    static let cyclopsHitsToKill = 8

    // MARK: Enemy attack accuracy vs rogue

    static let goblinHitChance = 0.40
    static let orcHitChance = 0.40
    static let slimeHitChance = 0.33
    static let blueSlimeHitChance = 0.33
    static let trollHitChance = 0.45
    static let cyclopsHitChance = 0.55

    // MARK: Death strips (frame counts match asset strips)

    static let orcDieFrameCount = 8
    static let goblinDieFrameCount = 8
    static let trollDieFrameCount = 8
    static let slimeDieFrameCount = 9
    static let cyclopsDieFrameCount = 14

    /// Per-frame duration for strip-based deaths; derived from overall death length and Orc strip length (existing tuning).
    static let deathStripFrameDuration: Double = GameConstants.deathAnimationDuration / Double(orcDieFrameCount)

    // MARK: Positions (points, same coordinate space as rogue / room)

    static let primaryEnemySlotPositions: [(x: CGFloat, y: CGFloat)] = [(33, -9), (29, 53), (39, 24)]
    static let trollPositions: [(x: CGFloat, y: CGFloat)] = [(19, 3), (38, 51)]
    static let slimePositions: [(x: CGFloat, y: CGFloat)] = [(11, 0), (43, -9), (11, 53), (43, 44)]
    static let cyclopsPosition: (x: CGFloat, y: CGFloat) = (33, 24)

    /// When `enemyCount` is 3, the middle enemy (index 1) is shifted 12pt left.
    static func primaryEnemySlotPosition(index: Int, enemyCount: Int) -> (x: CGFloat, y: CGFloat) {
        let i = max(0, min(index, primaryEnemySlotPositions.count - 1))
        let base = primaryEnemySlotPositions[i]
        if enemyCount == 3, i == 1 {
            return (base.x - 12, base.y)
        }
        return (base.x, base.y)
    }

    /// Idle start frame offsets for the three-enemy primary slot (goblin/orc stagger).
    static let primarySlotEnemyIdleStartFrames: [Int] = [4, 6, 0]

    static let cyclopsAttackOffsetXAdjustment: CGFloat = 6

    // MARK: Wave roll helpers

    static func enemyCount(forWaveRoll roll: Int) -> Int {
        switch EnemyWaveRoll(rawValue: roll) {
        case .some(.primarySlot): return 3
        case .some(.troll): return 2
        case .some(.slime): return 4
        case .some(.cyclops), .none: return 1
        }
    }
}
