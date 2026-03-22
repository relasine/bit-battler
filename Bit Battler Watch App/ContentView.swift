//
//  ContentView.swift
//  Bit Battler Watch App
//
//  Created by Kevin Simpson on 3/13/26.
//

import SwiftUI
import Foundation
import os
#if os(watchOS)
import WatchKit
import UIKit
#endif

private enum BitBattlerLog {
    static let game = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BitBattler", category: "Game")
}

#if os(watchOS)
/// Decodes gameplay bitmaps off the main thread before `Start` — first launch otherwise stalls on the asset catalog + rendering setup.
enum GameplayAssetPrewarm {
    private static let assetNames: [String] = [
        "Room", "Torch", "Arrow", "Heart", "Mana",
        "RogueIdle", "RogueAttack", "RogueWalk", "RogueDamage", "RogueDodge", "RogueDie", "RogueShuriken", "RogueBombThrow", "RogueKnifeThrow",
        "OrcIdle", "OrcAttack", "OrcDamage", "OrcDie",
        "GoblinIdle", "GoblinAttack", "GoblinDamage", "GoblinDie",
        "TrollIdle", "TrollAttack", "TrollDamage", "TrollDie",
        "SlimeIdle", "SlimeAttack", "SlimeDamage", "SlimeDead",
        "BlueSlimeIdle", "BlueSlimeAttack", "BlueSlimeDamage", "BlueSlimeDie",
        "CyclopsIdle", "CyclopsAttack", "CyclopsDamage", "CyclopsDead",
        "BombGround", "BombThrown", "ThrowingKnifeIcon", "KnifeThrown",
        "Heal", "ManaRestore",
        "SmallHealthPotion", "SmallManaPotion",
    ]

    /// Serial queue for shared prewarm state. (Swift 6: `DispatchQueue.sync` is unavailable inside GCD `async` closures.)
    private static let stateQueue = DispatchQueue(label: "com.bitbattler.gameplay.prewarm.state")
    private static var hasScheduledBackgroundWork = false
    private static var didFinishLoading = false
    private static var loadedCount = 0
    private static var completions: [() -> Void] = []

    private static func forceDecode(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private static func runPrewarmOnBackgroundQueue() {
        // Swift 6: `DispatchQueue.sync` uses locks and is unavailable from `Thread` blocks too (treated as async).
        // Use only `stateQueue.async` on this serial queue: FIFO guarantees the completion block runs after all increments.
        let thread = Thread {
            for (index, name) in assetNames.enumerated() {
                autoreleasepool {
                    if let image = UIImage(named: name) {
                        forceDecode(image)
                    } else {
                        BitBattlerLog.game.warning("GameplayAssetPrewarm: missing UIImage named \"\(name, privacy: .public)\"")
                        #if DEBUG
                        assertionFailure("Missing gameplay asset: \(name)")
                        #endif
                    }
                }
                stateQueue.async {
                    loadedCount += 1
                }

                // Yield briefly so watchOS can keep the title/loading UI responsive.
                if index.isMultiple(of: 3) {
                    Thread.sleep(forTimeInterval: 0.0015)
                }
            }

            stateQueue.async {
                didFinishLoading = true
                let toCall = completions
                completions.removeAll()
                DispatchQueue.main.async {
                    for f in toCall {
                        f()
                    }
                }
            }
        }
        thread.name = "GameplayAssetPrewarm"
        thread.qualityOfService = .utility
        thread.start()
    }

    static var progress: Double {
        stateQueue.sync {
            let loaded = loadedCount
            let total = assetNames.count
            guard total > 0 else { return 1.0 }
            return min(1, Double(loaded) / Double(total))
        }
    }

    static var isComplete: Bool {
        stateQueue.sync { didFinishLoading }
    }

    static var progressLabel: String {
        stateQueue.sync {
            let loaded = loadedCount
            return "\(min(loaded, assetNames.count))/\(assetNames.count)"
        }
    }

    /// Fire-and-forget prewarm once loading UI is visible.
    static func ensureStarted() {
        let shouldSchedule = stateQueue.sync { () -> Bool in
            let shouldSchedule = !hasScheduledBackgroundWork
            if shouldSchedule {
                hasScheduledBackgroundWork = true
                loadedCount = 0
            }
            return shouldSchedule
        }

        guard shouldSchedule else { return }
        runPrewarmOnBackgroundQueue()
    }

    /// Runs on the main queue after the UIImage pass completes (immediately if it already finished).
    static func whenComplete(execute body: @escaping () -> Void) {
        let (runImmediatelyOnMain, shouldSchedulePrewarm) = stateQueue.sync { () -> (Bool, Bool) in
            if didFinishLoading {
                return (true, false)
            }
            completions.append(body)
            let shouldSchedule = !hasScheduledBackgroundWork
            if shouldSchedule {
                hasScheduledBackgroundWork = true
            }
            return (false, shouldSchedule)
        }

        if runImmediatelyOnMain {
            DispatchQueue.main.async(execute: body)
            return
        }

        guard shouldSchedulePrewarm else { return }
        runPrewarmOnBackgroundQueue()
    }
}
#endif

#if os(watchOS)
private struct PrewarmProgressBar: View {
    var showsLabel: Bool = true
    var hideWhenComplete: Bool = true

    private static let pollInterval: TimeInterval = 0.1

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.pollInterval)) { _ in
            let progress = GameplayAssetPrewarm.progress
            let shouldShow = !hideWhenComplete || progress < 1

            if shouldShow {
                VStack(spacing: 6) {
                    ProgressView(value: progress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.red)
                        .scaleEffect(x: 1, y: 0.85, anchor: .center)

                    if showsLabel {
                        Text("Loading \(GameplayAssetPrewarm.progressLabel)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
        }
    }
}
#endif

private enum RootScreen {
    case title
    case loading
    case game
    case info
}

/// Bomb (skill) and Throwing Knife (item) share the same on-field target picker UI.
private enum InventoryEnemyTargetItem: Equatable {
    case bomb
    case throwingKnife
}

/// Long-press detail sheet for inventory items and skills (Items / Skills menus).
private struct ItemOrSkillDetailPayload: Equatable {
    let title: String
    let description: String
}

private enum InventoryItemAndSkillDescriptions {
    static func description(forInventoryItem name: String) -> String? {
        switch name {
        case "Sm Health Pot": return "Restores 1 HP"
        case "Sm Mana Pot": return "Restores 1 mana"
        case "Throwing Knife": return "Make a free attack at 2 damage"
        default: return nil
        }
    }

    static func description(forSkill name: String) -> String? {
        switch name {
        case "Shuriken": return "Strike every enemy for 1 damage"
        case "Bomb": return "Strike an enemy for 2 damage and reset their initiative"
        default: return nil
        }
    }
}

struct EnemyHitFloatState: Equatable {
    let startDate: Date
    let damageAmount: Int
    let showCritBang: Bool
}

struct ContentView: View {
    @State private var isRogueAttacking = false
    @State private var attackStartDate: Date?
    @State private var isAttackInputLocked = false
    @State private var isRogueWalking = false
    @State private var walkStartDate: Date?
    @State private var isRoomWiping = false
    /// \(1 -> -1\): 1 starts off-screen right, -1 ends off-screen left.
    @State private var roomWipeProgress: CGFloat = 1
    @State private var rogueOffsetX: CGFloat = GameConstants.rogueIdleOffsetX
    @State private var rogueOffsetY: CGFloat = GameConstants.rogueIdleOffsetY
    @State private var damagedEnemyIndex: Int? = nil
    @State private var enemyDamageStartDate: Date? = nil
    @State private var isTrollWave: Bool = false
    @State private var isSlimeWave: Bool = false
    @State private var isCyclopsWave: Bool = false
    @State private var enemyCount: Int = 2
    @State private var enemyStates: [EnemyState] = []
    @State private var totalHitsUsed: Int = 0
    @State private var showResetConfirmation = false
    @State private var showGameOverPopup = false
    @State private var rootScreen: RootScreen = .title
    /// Title screen: show loading overlay until gameplay assets are prewarmed (watchOS).
    @State private var isStartLoadingGame = false
    @State private var gameSessionId = UUID()
    @State private var roomNumber: Int = GameConstants.startingRoomNumber

    // Rogue health / game-over.
    @State private var heartsRemaining: Int = GameConstants.heartsInitial
    @State private var manaRemaining: Int = GameConstants.manaInitial
    @State private var isRogueDead: Bool = false
    @State private var rogueDamageStartDate: Date? = nil
    @State private var rogueDieStartDate: Date? = nil
    @State private var rogueDodgeStartDate: Date? = nil

    @State private var inventoryStacks: [InventoryStack] = []
    /// The enemy index whose death animation should spawn the room's item drop.
    @State private var potionDropEnemyIndex: Int? = nil
    /// Asset for the drop: potion or throwing knife icon names (see `randomRoomDropImageName()`).
    @State private var potionDropImageName: String? = nil

    // Inventory UI.
    @State private var inventoryCrownDetent: Double = 0
    @State private var isInventoryConsumePending: Bool = false
    /// Hides the Items overlay immediately when dismissing; crown binding can leave `inventoryCrownDetent > 0.5`.
    @State private var suppressItemsMenuOverlay: Bool = false

    // Skills.
    @State private var showSkillSheet: Bool = false
    @State private var itemOrSkillDetail: ItemOrSkillDetailPayload? = nil
    @State private var skillToastMessage: String? = nil
    @State private var skillToastDismissId = UUID()
    @State private var shurikenStartDate: Date? = nil
    @State private var isShurikenActive: Bool = false
    @State private var shurikenDamageApplied: Bool = false
    
    /// enemyIndex -> floating hit text (damage amount + optional crit bang; clears automatically).
    @State private var enemyHitFloatStates: [Int: EnemyHitFloatState] = [:]

    // Healing effect (8-frame sprite sheet).
    @State private var healEffectStartDate: Date? = nil
    // Mana restore effect (8-frame sprite sheet).
    @State private var manaRestoreEffectStartDate: Date? = nil

    // Bomb skill + knife item: field target picker; bomb throw VFX.
    @State private var inventoryEnemyTargetItem: InventoryEnemyTargetItem? = nil
    @State private var isBombThrowActive: Bool = false
    @State private var bombThrowStartDate: Date? = nil
    @State private var bombTargetIndex: Int? = nil
    @State private var bombProjectileStartDate: Date? = nil
    @State private var bombGroundStartDate: Date? = nil

    // Throwing Knife (throw + projectile; does not advance enemy turn / hit tallies).
    @State private var isKnifeThrowActive: Bool = false
    @State private var knifeThrowStartDate: Date? = nil
    @State private var knifeTargetIndex: Int? = nil
    @State private var knifeProjectileStartDate: Date? = nil

    // Enemy auto-attacks (per-enemy readiness in `EnemyState.rogueAttacksUntilEnemyTurn`).
    @State private var isEnemyAttackSequenceInProgress: Bool = false
    @State private var enemyAttackQueue: [Int] = []
    @State private var enemyAttackQueuePosition: Int = 0
    @State private var activeEnemyAttackingIndex: Int? = nil
    @State private var activeEnemyAttackStartDate: Date? = nil
    /// Enemy retaliation phases queued by rogue attacks.
    @State private var pendingEnemyAttackPhases: Int = 0

    /// `roll == 0` wave: goblin art in rooms 1–9, Orc enemy art from room 10+.
    private var isPrimaryEnemySlotWave: Bool {
        !isSlimeWave && !isTrollWave && !isCyclopsWave
    }

    private var isGoblinWave: Bool {
        isPrimaryEnemySlotWave && roomNumber < 10
    }

    /// Primary slot (roll 0), room 10+: the Orc enemy type (group of 3, four hits, Orc* assets).
    private var isOrcEnemyWave: Bool {
        isPrimaryEnemySlotWave && roomNumber >= 10
    }

    /// Single source for wave combat + art after room flags are set (`resetEnemies` updates those flags first).
    private var enemyWaveProfile: EnemyWaveProfile {
        EnemyWaveProfile.resolve(isSlimeWave: isSlimeWave, isTrollWave: isTrollWave, isCyclopsWave: isCyclopsWave, roomNumber: roomNumber)
    }

    private var canTapEnemies: Bool {
        // HealthKit has been removed from this app; attacks are no longer limited by step count.
        return !isBombThrowActive
            && !isKnifeThrowActive
            && !isRogueDead
            && rogueDamageStartDate == nil
            && rogueDieStartDate == nil
            && !isEnemyAttackSequenceInProgress
    }

    private var rogueAttackDuration: Double {
        Double(GameConstants.attackFrameCount) * GameConstants.attackFrameDuration
    }

    private func playLightHeartLostHaptic() {
        // Lightweight `.click` for rogue taking damage, and for critical hits when enemy damage starts.
        #if os(watchOS)
        WKInterfaceDevice.current().play(.click)
        #endif
    }

    private var canConsumeItems: Bool {
        !isBombThrowActive && !isKnifeThrowActive && !isRogueDead && rogueDamageStartDate == nil && rogueDieStartDate == nil
    }

    private var isInventoryEnemyTargetSelectionActive: Bool {
        inventoryEnemyTargetItem != nil
    }

    private func addSmallHealthPotionToInventory() {
        let displayName = "Sm Health Pot"
        if let idx = inventoryStacks.firstIndex(where: { $0.displayName == displayName }) {
            inventoryStacks[idx].count += 1
        } else {
            inventoryStacks.append(InventoryStack(displayName: displayName, count: 1))
        }
    }

    private func consumeSmallHealthPotionStack() {
        let displayName = "Sm Health Pot"
        guard let idx = inventoryStacks.firstIndex(where: { $0.displayName == displayName }) else { return }
        guard inventoryStacks[idx].count > 0 else { return }

        inventoryStacks[idx].count -= 1
        if inventoryStacks[idx].count <= 0 {
            inventoryStacks.remove(at: idx)
        }

        heartsRemaining = min(GameConstants.heartsInitial, heartsRemaining + 1)
        schedulePostConsumeItemsMenuDismiss()
    }

    private func addSmallManaPotionToInventory() {
        let displayName = "Sm Mana Pot"
        if let idx = inventoryStacks.firstIndex(where: { $0.displayName == displayName }) {
            inventoryStacks[idx].count += 1
        } else {
            inventoryStacks.append(InventoryStack(displayName: displayName, count: 1))
        }
    }

    private func addThrowingKnifeToInventory() {
        let displayName = "Throwing Knife"
        if let idx = inventoryStacks.firstIndex(where: { $0.displayName == displayName }) {
            inventoryStacks[idx].count += 1
        } else {
            inventoryStacks.append(InventoryStack(displayName: displayName, count: 1))
        }
    }

    @discardableResult
    private func consumeThrowingKnifeStack() -> Bool {
        let displayName = "Throwing Knife"
        guard let idx = inventoryStacks.firstIndex(where: { $0.displayName == displayName }) else { return false }
        guard inventoryStacks[idx].count > 0 else { return false }

        inventoryStacks[idx].count -= 1
        if inventoryStacks[idx].count <= 0 {
            inventoryStacks.remove(at: idx)
        }
        schedulePostConsumeItemsMenuDismiss()
        return true
    }

    private func consumeSmallManaPotionStack() {
        let displayName = "Sm Mana Pot"
        guard let idx = inventoryStacks.firstIndex(where: { $0.displayName == displayName }) else { return }
        guard inventoryStacks[idx].count > 0 else { return }

        inventoryStacks[idx].count -= 1
        if inventoryStacks[idx].count <= 0 {
            inventoryStacks.remove(at: idx)
        }

        manaRemaining = min(GameConstants.manaInitial, manaRemaining + 1)
        schedulePostConsumeItemsMenuDismiss()
    }

    private func startManaRestoreEffect(forSession sessionId: UUID) {
        let effectStart = Date()
        manaRestoreEffectStartDate = effectStart

        DispatchQueue.main.asyncAfter(deadline: .now() + GameConstants.manaRestoreEffectDuration) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                if manaRestoreEffectStartDate == effectStart {
                    manaRestoreEffectStartDate = nil
                }
            }
        }
    }

    /// Room drop shown on the last enemy's death (health, mana, or throwing knife).
    private func randomRoomDropImageName() -> String {
        switch Int.random(in: 0..<3) {
        case 0: return "SmallHealthPotion"
        case 1: return "SmallManaPotion"
        default: return "ThrowingKnifeIcon"
        }
    }

    private func addRoomDropItemToInventory(assetImageName: String) {
        switch assetImageName {
        case "SmallManaPotion":
            addSmallManaPotionToInventory()
        case "SmallHealthPotion":
            addSmallHealthPotionToInventory()
        case "ThrowingKnifeIcon":
            addThrowingKnifeToInventory()
        default:
            break
        }
    }

    private func inventoryStackButtonLabel(_ stack: InventoryStack) -> String {
        if stack.count <= 1 {
            return stack.displayName
        }
        return "\(stack.displayName) x\(stack.count)"
    }

    /// Dims inventory rows; health/mana pots also use this to disable taps when at max or otherwise unusable.
    private func inventoryStackAppearsUsable(_ stack: InventoryStack) -> Bool {
        switch stack.displayName {
        case "Sm Health Pot":
            return canConsumeItems && stack.count > 0 && heartsRemaining < GameConstants.heartsInitial
        case "Sm Mana Pot":
            return canConsumeItems && stack.count > 0 && manaRemaining < GameConstants.manaInitial
        case "Throwing Knife":
            return canConsumeItems && hasLivingEnemies && stack.count > 0
        default:
            return false
        }
    }

    /// Match the Items sheet close control so `digitalCrownRotation` stays in sync with the overlay.
    private func dismissItemsMenu() {
        suppressItemsMenuOverlay = true
        withTransaction(Transaction(animation: .easeInOut(duration: 0.15))) {
            inventoryCrownDetent = 0
        }
    }

    /// Crown × `digitalCrownRotation` can ignore the first programmatic dismiss or snap detent back after
    /// inventory updates (e.g. potion consumed). Re-dismiss on the next run loop.
    private func schedulePostConsumeItemsMenuDismiss() {
        DispatchQueue.main.async {
            dismissItemsMenu()
        }
    }

    private func startHealEffect(forSession sessionId: UUID) {
        let effectStart = Date()
        healEffectStartDate = effectStart

        DispatchQueue.main.asyncAfter(deadline: .now() + GameConstants.healEffectDuration) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                if healEffectStartDate == effectStart {
                    healEffectStartDate = nil
                }
            }
        }
    }
    
    private func triggerEnemyHitFloat(forEnemyIndex enemyIndex: Int, damageAmount: Int, showCritBang: Bool, startDate: Date, forSession sessionId: UUID) {
        let state = EnemyHitFloatState(startDate: startDate, damageAmount: damageAmount, showCritBang: showCritBang)
        enemyHitFloatStates[enemyIndex] = state

        DispatchQueue.main.asyncAfter(deadline: .now() + GameConstants.critTextDuration) {
            guard gameSessionId == sessionId else { return }
            guard enemyHitFloatStates[enemyIndex]?.startDate == startDate else { return }
            withTransaction(Transaction(animation: nil)) {
                enemyHitFloatStates[enemyIndex] = nil
            }
        }
    }

    private var enemyDamageDelay: Double {
        3 * GameConstants.attackFrameDuration
    }

    private var enemyDamageDuration: Double {
        Double(GameConstants.attackFrameCount) * GameConstants.attackFrameDuration
    }

    private var postDamageTapCooldownDuration: Double {
        0.01
    }

    private var enemyDeathAnimationDuration: Double {
        enemyWaveProfile.deathAnimationDuration
    }

    private func enemyPosition(index: Int) -> (x: CGFloat, y: CGFloat) {
        enemyWaveProfile.position(index: index, enemyCount: enemyCount)
    }

    private func wipeToNextWaveAndReset() {
        guard !isRoomWiping else { return }

        let wipeDuration = GameConstants.roomWipeDuration

        withTransaction(Transaction(animation: nil)) {
            isRoomWiping = true
            roomWipeProgress = 1
        }

        withAnimation(.linear(duration: wipeDuration)) {
            roomWipeProgress = -1
        }

        // Reset while fully covered (midpoint of travel).
        DispatchQueue.main.asyncAfter(deadline: .now() + wipeDuration / 2) {
            withTransaction(Transaction(animation: nil)) {
                resetEnemies()
                roomNumber += 1
                // New room: reset pending enemy retaliation (per-enemy cadence reset in `resetEnemies`).
                pendingEnemyAttackPhases = 0
                isEnemyAttackSequenceInProgress = false
                enemyAttackQueue = []
                enemyAttackQueuePosition = 0
                activeEnemyAttackingIndex = nil
                activeEnemyAttackStartDate = nil
                rogueDamageStartDate = nil
                rogueDieStartDate = nil
                isRogueDead = false
                isRogueWalking = false
                walkStartDate = nil
                rogueOffsetX = GameConstants.rogueIdleOffsetX
                rogueOffsetY = GameConstants.rogueIdleOffsetY

                // Clear potion tracking for the next room.
                potionDropEnemyIndex = nil
                potionDropImageName = nil

                inventoryEnemyTargetItem = nil
                isBombThrowActive = false
                bombThrowStartDate = nil
                bombTargetIndex = nil
                bombProjectileStartDate = nil
                bombGroundStartDate = nil
                isKnifeThrowActive = false
                knifeThrowStartDate = nil
                knifeTargetIndex = nil
                knifeProjectileStartDate = nil
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + wipeDuration) {
            withTransaction(Transaction(animation: nil)) {
                isRoomWiping = false
                roomWipeProgress = 1
            }
        }
    }

    private func startRogueWalkToNextWave(arrowOffsetX: CGFloat, arrowOffsetY: CGFloat) {
        guard !isRogueAttacking else { return }
        guard !isRogueWalking else { return }
        guard !isRoomWiping else { return }
        guard !isEnemyAttackSequenceInProgress else { return }
        guard !isBombThrowActive else { return }
        guard !isKnifeThrowActive else { return }
        guard !isInventoryEnemyTargetSelectionActive else { return }
        guard !isRogueDead else { return }
        guard rogueDamageStartDate == nil else { return }
        guard rogueDieStartDate == nil else { return }

        let sessionId = gameSessionId
        let fromX = rogueOffsetX
        let fromY = rogueOffsetY
        let toX = arrowOffsetX
        let toY = arrowOffsetY

        let distance = hypot(Double(toX - fromX), Double(toY - fromY))
        let duration = max(0.35, min(1.25, distance / GameConstants.rogueWalkSpeedPointsPerSecond))

        withTransaction(Transaction(animation: nil)) {
            isRogueWalking = true
            walkStartDate = Date()
        }

        // Translate in discrete 3px steps while `RogueWalk` animates.
        let stepPx = max(1, Int(GameConstants.rogueWalkTranslationStepPx))
        let dx = Double(toX - fromX)
        let dy = Double(toY - fromY)
        let steps = max(1, Int(ceil(max(abs(dx), abs(dy)) / Double(stepPx))))
        let interval = duration / Double(steps)

        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Double(i) * interval)) {
                guard gameSessionId == sessionId else { return }
                let t = Double(i) / Double(steps)
                let rawX = Double(fromX) + (dx * t)
                let rawY = Double(fromY) + (dy * t)
                let snappedX = Double(stepPx) * round(rawX / Double(stepPx))
                let snappedY = Double(stepPx) * round(rawY / Double(stepPx))
                withTransaction(Transaction(animation: nil)) {
                    rogueOffsetX = CGFloat(snappedX)
                    rogueOffsetY = CGFloat(snappedY)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard gameSessionId == sessionId else { return }
            wipeToNextWaveAndReset()
        }
    }

    private func resetEnemies() {
        // New enemy wave types:
        // - Slime: 4 enemies; 2 hits (green) until room 10+, then blue slimes with 3 hits each
        // - Cyclops: 1 enemy, 8 hits, death animation spans 14 frames
        // - Primary enemy slot (roll 0): 3 goblins (rooms 1–9) or 3 Orc enemies (room 10+, 4 hits each)
        // - Trolls: existing wave logic
        let roll = Int.random(in: 0..<EnemyWaveRoll.allCases.count)
        isSlimeWave = roll == 2
        isCyclopsWave = roll == 3

        isTrollWave = roll == 1

        enemyCount = EnemiesConstants.enemyCount(forWaveRoll: roll)

        let hitsToKill = enemyWaveProfile.hitsToKill

        enemyStates = (0..<enemyCount).map { _ in
            EnemyState(
                hitCount: 0,
                hitsToKill: hitsToKill,
                dead: false,
                dying: false,
                deathStartDate: nil,
                rogueAttacksUntilEnemyTurn: GameConstants.rogueAttacksPerEnemyAttackCycle
            )
        }
        
        // Clear transient per-enemy text overlays between waves.
        enemyHitFloatStates.removeAll()
        
        damagedEnemyIndex = nil
        enemyDamageStartDate = nil

        // Reset potion tracking for the new wave.
        potionDropEnemyIndex = nil
        potionDropImageName = nil
    }

    private var enemyAttackDuration: Double {
        Double(GameConstants.enemyAttackFrameCount) * GameConstants.enemyAttackFrameDuration
    }

    private var rogueDamageDuration: Double {
        Double(GameConstants.rogueDamageFrameCount) * GameConstants.rogueDamageFrameDuration
    }

    private var rogueDieDuration: Double {
        GameConstants.rogueDieAnimationDuration
    }

    private var currentEnemyHitChance: Double {
        enemyWaveProfile.enemyHitChance
    }

    private static let maxPendingEnemyDamagePollRetries = 20

    private func maybeStartPendingEnemyAttack(forSession sessionId: UUID, retryCount: Int = 0) {
        guard gameSessionId == sessionId else { return }
        guard pendingEnemyAttackPhases > 0 else { return }
        guard !isEnemyAttackSequenceInProgress else { return }
        guard !isRogueDead else { return }
        guard !isRogueWalking else { return }
        guard !isRoomWiping else { return }
        guard rogueDamageStartDate == nil else { return }
        guard rogueDieStartDate == nil else { return }

        // Delay enemy retaliation until any in-flight enemy damage animation from the last rogue hits completes.
        if damagedEnemyIndex != nil || enemyDamageStartDate != nil {
            if let start = enemyDamageStartDate {
                let elapsed = Date().timeIntervalSince(start)
                let remaining = max(0, enemyDamageDuration - elapsed)
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining + 0.02) {
                    maybeStartPendingEnemyAttack(forSession: sessionId, retryCount: 0)
                }
            } else {
                if retryCount >= Self.maxPendingEnemyDamagePollRetries {
                    BitBattlerLog.game.fault("maybeStartPendingEnemyAttack: clearing stuck damage overlay state after \(Self.maxPendingEnemyDamagePollRetries) retries")
                    withTransaction(Transaction(animation: nil)) {
                        damagedEnemyIndex = nil
                        enemyDamageStartDate = nil
                    }
                    maybeStartPendingEnemyAttack(forSession: sessionId, retryCount: 0)
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    maybeStartPendingEnemyAttack(forSession: sessionId, retryCount: retryCount + 1)
                }
            }
            return
        }

        startEnemyAttackSequence(forSession: sessionId)
    }

    /// Rogue melee, shuriken, and bomb each count as one "attack action" for every living enemy's retaliation timer (Throwing Knife does not).
    private func applyRogueAttackActionAdvancingEnemyTurns() {
        for i in 0..<enemyStates.count {
            guard !enemyStates[i].dead && !enemyStates[i].dying else { continue }
            enemyStates[i].rogueAttacksUntilEnemyTurn -= 1
        }
        let anyReady = enemyStates.contains { !$0.dead && !$0.dying && $0.rogueAttacksUntilEnemyTurn <= 0 }
        if anyReady {
            pendingEnemyAttackPhases += 1
        }
    }

    private func startEnemyAttackSequence(forSession sessionId: UUID) {
        guard gameSessionId == sessionId else { return }
        guard !isRogueDead else { return }
        let ready: [Int] = (0..<enemyStates.count).filter { i in
            !enemyStates[i].dead && !enemyStates[i].dying && enemyStates[i].rogueAttacksUntilEnemyTurn <= 0
        }.sorted()
        guard !ready.isEmpty else {
            pendingEnemyAttackPhases = max(0, pendingEnemyAttackPhases - 1)
            maybeStartPendingEnemyAttack(forSession: sessionId)
            return
        }

        pendingEnemyAttackPhases = max(0, pendingEnemyAttackPhases - 1)

        enemyAttackQueue = ready
        enemyAttackQueuePosition = 0
        isEnemyAttackSequenceInProgress = true
        activeEnemyAttackingIndex = nil
        activeEnemyAttackStartDate = nil
        attackNextEnemy(forSession: sessionId)
    }

    private func stopEnemyAttackSequence() {
        isEnemyAttackSequenceInProgress = false
        enemyAttackQueue = []
        enemyAttackQueuePosition = 0
        activeEnemyAttackingIndex = nil
        activeEnemyAttackStartDate = nil
    }

    private func attackNextEnemy(forSession sessionId: UUID) {
        guard gameSessionId == sessionId else { return }
        guard isEnemyAttackSequenceInProgress else { return }
        guard !isRogueDead else { return }

        guard enemyAttackQueuePosition < enemyAttackQueue.count else {
            stopEnemyAttackSequence()
            maybeStartPendingEnemyAttack(forSession: sessionId)
            return
        }

        let enemyIndex = enemyAttackQueue[enemyAttackQueuePosition]
        enemyAttackQueuePosition += 1

        guard enemyIndex >= 0, enemyIndex < enemyStates.count else {
            attackNextEnemy(forSession: sessionId)
            return
        }
        guard !enemyStates[enemyIndex].dead, !enemyStates[enemyIndex].dying else {
            attackNextEnemy(forSession: sessionId)
            return
        }

        let didHit = Double.random(in: 0..<1) < currentEnemyHitChance

        // Start enemy visuals/translation with a brief pre-delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + GameConstants.enemyAttackPreDelay) {
            guard gameSessionId == sessionId else { return }

            let attackStart = Date()
            withTransaction(Transaction(animation: nil)) {
                activeEnemyAttackingIndex = enemyIndex
                activeEnemyAttackStartDate = attackStart
                if didHit {
                    if heartsRemaining > 0 {
                        heartsRemaining = max(0, heartsRemaining - 1)
                        playLightHeartLostHaptic()
                    }
                    rogueOffsetX = GameConstants.rogueIdleOffsetX - GameConstants.rogueHitKnockbackPx
                    rogueDamageStartDate = attackStart
                } else {
                    rogueDodgeStartDate = attackStart
                    // Start at idle, then translate left gradually during the dodge window.
                    rogueOffsetX = GameConstants.rogueIdleOffsetX
                }
            }

            if !didHit {
                let step = max(1, Int(GameConstants.rogueDodgeTranslationStepPx))
                let total = max(step, Int(GameConstants.rogueMissDodgeKnockbackPx))
                let stepCount = max(1, total / step)
                let translationDuration = max(0.01, enemyAttackDuration * GameConstants.rogueDodgeTranslationDurationMultiplier)
                let stepInterval = translationDuration / Double(stepCount)

                // Move in discrete 3px steps to the left, faster than the full dodge window.
                for i in 1...stepCount {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (Double(i) * stepInterval)) {
                        guard gameSessionId == sessionId else { return }
                        withTransaction(Transaction(animation: nil)) {
                            rogueOffsetX = GameConstants.rogueIdleOffsetX - (CGFloat(i) * CGFloat(step))
                        }
                    }
                }
            }

            if didHit {
                DispatchQueue.main.asyncAfter(deadline: .now() + rogueDamageDuration) {
                    guard gameSessionId == sessionId else { return }
                    withTransaction(Transaction(animation: nil)) {
                        activeEnemyAttackingIndex = nil
                        activeEnemyAttackStartDate = nil
                        rogueDamageStartDate = nil
                        rogueDodgeStartDate = nil
                        if heartsRemaining > 0 {
                            rogueOffsetX = GameConstants.rogueIdleOffsetX
                        }
                        if enemyIndex < enemyStates.count, !enemyStates[enemyIndex].dead {
                            enemyStates[enemyIndex].rogueAttacksUntilEnemyTurn = GameConstants.rogueAttacksPerEnemyAttackCycle
                        }
                    }

                    if heartsRemaining <= 0 {
                        stopEnemyAttackSequence()
                        startRogueDie(forSession: sessionId)
                    } else {
                        attackNextEnemy(forSession: sessionId)
                    }
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + enemyAttackDuration) {
                    guard gameSessionId == sessionId else { return }
                    withTransaction(Transaction(animation: nil)) {
                        activeEnemyAttackingIndex = nil
                        activeEnemyAttackStartDate = nil
                        rogueDodgeStartDate = nil
                        // Snap back immediately after the dodge window completes.
                        rogueOffsetX = GameConstants.rogueIdleOffsetX
                        if enemyIndex < enemyStates.count, !enemyStates[enemyIndex].dead {
                            enemyStates[enemyIndex].rogueAttacksUntilEnemyTurn = GameConstants.rogueAttacksPerEnemyAttackCycle
                        }
                    }
                    attackNextEnemy(forSession: sessionId)
                }
            }
        }
    }

    private func startRogueDie(forSession sessionId: UUID) {
        guard gameSessionId == sessionId else { return }
        guard !isRogueDead else { return }

        withTransaction(Transaction(animation: nil)) {
            rogueDieStartDate = Date()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + rogueDieDuration) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                isRogueDead = true
                rogueDieStartDate = nil
            }
            // After the death animation completes, wait briefly before showing Game Over.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard gameSessionId == sessionId else { return }
                withTransaction(Transaction(animation: nil)) {
                    showGameOverPopup = true
                }
            }
        }
    }

    private func resetGameToInitialState() {
        BitBattlerLog.game.info("resetGameToInitialState: new session")
        gameSessionId = UUID()
        roomNumber = GameConstants.startingRoomNumber
        totalHitsUsed = 0
        heartsRemaining = GameConstants.heartsInitial
        manaRemaining = GameConstants.manaInitial
        isRogueDead = false
        rogueDamageStartDate = nil
        rogueDieStartDate = nil
        rogueDodgeStartDate = nil
        showGameOverPopup = false
        showResetConfirmation = false

        isEnemyAttackSequenceInProgress = false
        enemyAttackQueue = []
        enemyAttackQueuePosition = 0
        activeEnemyAttackingIndex = nil
        activeEnemyAttackStartDate = nil
        pendingEnemyAttackPhases = 0

        isRogueAttacking = false
        attackStartDate = nil
        isAttackInputLocked = false
        isRogueWalking = false
        walkStartDate = nil
        isRoomWiping = false
        roomWipeProgress = 1
        rogueOffsetX = GameConstants.rogueIdleOffsetX
        rogueOffsetY = GameConstants.rogueIdleOffsetY

        damagedEnemyIndex = nil
        enemyDamageStartDate = nil

        isTrollWave = false
        isSlimeWave = false
        isCyclopsWave = false
        enemyCount = 2

        // Reset inventory + potion tracking.
        inventoryStacks = []
        potionDropEnemyIndex = nil
        potionDropImageName = nil

        isInventoryConsumePending = false
        healEffectStartDate = nil
        manaRestoreEffectStartDate = nil
        inventoryCrownDetent = 0
        suppressItemsMenuOverlay = false

        inventoryEnemyTargetItem = nil
        isBombThrowActive = false
        bombThrowStartDate = nil
        bombTargetIndex = nil
        bombProjectileStartDate = nil
        bombGroundStartDate = nil
        isKnifeThrowActive = false
        knifeThrowStartDate = nil
        knifeTargetIndex = nil
        knifeProjectileStartDate = nil

        showSkillSheet = false
        itemOrSkillDetail = nil
        skillToastMessage = nil
        skillToastDismissId = UUID()
        shurikenStartDate = nil
        isShurikenActive = false
        shurikenDamageApplied = false
        enemyHitFloatStates.removeAll()

        resetEnemies()
    }

    private func returnToTitleScreenResettingGame() {
        withTransaction(Transaction(animation: nil)) {
            resetGameToInitialState()
            rootScreen = .title
            isStartLoadingGame = false
        }
    }

#if os(watchOS)
    /// Use a dedicated loading screen so watchOS can render immediate feedback
    /// instead of composing an overlay on top of the title tree.
    private func beginTransitionFromTitleToGame() {
        guard !isStartLoadingGame else { return }
        isStartLoadingGame = true
        DispatchQueue.main.async {
            withTransaction(Transaction(animation: nil)) {
                rootScreen = .loading
            }
        }
    }

    private func continueFromLoadingScreenWhenPrewarmCompletes() {
        guard isStartLoadingGame, rootScreen == .loading else { return }
        GameplayAssetPrewarm.ensureStarted()
        GameplayAssetPrewarm.whenComplete {
            DispatchQueue.main.async {
                withTransaction(Transaction(animation: nil)) {
                    rootScreen = .game
                }
                DispatchQueue.main.async {
                    withTransaction(Transaction(animation: nil)) {
                        isStartLoadingGame = false
                    }
                }
            }
        }
    }
#endif

    private var bitBattlerTitleFont: Font {
        Font.custom("Press Start 2P", size: 11)
    }

    private var hasLivingEnemies: Bool {
        enemyStates.contains { !$0.dead && !$0.dying }
    }

    /// Shuriken / Bomb: used for tap gating + dimmed appearance. Kept non-`.disabled` so long-press (description) always receives gestures.
    private var canUseManaSkills: Bool {
        hasLivingEnemies && manaRemaining > 0 && !isBombThrowActive && !isKnifeThrowActive && !isInventoryEnemyTargetSelectionActive
    }

    /// When false, `canUseManaSkills` may be false for several reasons; this isolates "out of mana" for feedback.
    private var manaSkillsUnavailableOnlyDueToMana: Bool {
        hasLivingEnemies && manaRemaining == 0 && !isBombThrowActive && !isKnifeThrowActive && !isInventoryEnemyTargetSelectionActive
    }

    private func presentSkillToast(_ message: String, duration: TimeInterval = 1.8) {
        withAnimation(.easeInOut(duration: 0.2)) {
            skillToastMessage = message
        }
        let dismissId = UUID()
        skillToastDismissId = dismissId
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            guard skillToastDismissId == dismissId else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                skillToastMessage = nil
            }
        }
    }

    private func startBombThrow(targetIndex index: Int) {
        let sessionId = gameSessionId
        guard !isBombThrowActive else { return }
        guard !isKnifeThrowActive else { return }
        guard !isShurikenActive else { return }
        guard !isRogueWalking else { return }
        guard index >= 0, index < enemyStates.count else { return }
        guard !enemyStates[index].dead, !enemyStates[index].dying else { return }
        guard manaRemaining > 0 else {
            withTransaction(Transaction(animation: nil)) {
                inventoryEnemyTargetItem = nil
                inventoryCrownDetent = 0
            }
            return
        }

        withTransaction(Transaction(animation: nil)) {
            inventoryEnemyTargetItem = nil
            inventoryCrownDetent = 0
            manaRemaining = max(0, manaRemaining - 1)
        }

        applyRogueAttackActionAdvancingEnemyTurns()
        totalHitsUsed += 1

        let throwStart = Date()
        withTransaction(Transaction(animation: nil)) {
            isBombThrowActive = true
            bombThrowStartDate = throwStart
            bombTargetIndex = index
            bombProjectileStartDate = nil
            bombGroundStartDate = nil
            isAttackInputLocked = true
        }

        let projLaunch = Double(GameConstants.bombProjectileLaunchFrame - 1) * GameConstants.bombThrowFrameDuration
        let projLand = projLaunch + GameConstants.bombProjectileDuration
        let damageTime = projLand + Double(GameConstants.bombGroundDamageFrame - 1) * GameConstants.bombGroundFrameDuration
        let groundEnd = projLand + GameConstants.bombGroundDuration
        let unlockTime = damageTime + enemyDamageDuration

        DispatchQueue.main.asyncAfter(deadline: .now() + projLaunch) {
            guard gameSessionId == sessionId else { return }
            guard isBombThrowActive else { return }
            withTransaction(Transaction(animation: nil)) {
                bombProjectileStartDate = Date()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + projLand) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                bombProjectileStartDate = nil
                bombGroundStartDate = Date()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + damageTime) {
            guard gameSessionId == sessionId else { return }
            guard index < enemyStates.count else { return }
            guard !enemyStates[index].dead, !enemyStates[index].dying else { return }

            let didBombCrit = Double.random(in: 0..<1) < GameConstants.rogueCriticalHitChance
            enemyStates[index].hitCount += didBombCrit ? 3 : 2
            // Stun: only the bombed enemy's retaliation tally resets.
            enemyStates[index].rogueAttacksUntilEnemyTurn = GameConstants.rogueAttacksPerEnemyAttackCycle

            withTransaction(Transaction(animation: nil)) {
                damagedEnemyIndex = index
                enemyDamageStartDate = Date()
                let dmg = didBombCrit ? 3 : 2
                if didBombCrit {
                    playLightHeartLostHaptic()
                }
                triggerEnemyHitFloat(forEnemyIndex: index, damageAmount: dmg, showCritBang: didBombCrit, startDate: Date(), forSession: sessionId)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + enemyDamageDuration) {
                guard gameSessionId == sessionId else { return }
                guard index < enemyStates.count else { return }
                withTransaction(Transaction(animation: nil)) {
                    damagedEnemyIndex = nil
                    enemyDamageStartDate = nil
                }
                if enemyStates[index].hitCount >= enemyStates[index].hitsToKill, !enemyStates[index].dead, !enemyStates[index].dying {
                    let isLastDyingStart = enemyStates.enumerated().allSatisfy { (i, s) in
                        if i == index { return true }
                        return s.dead || s.dying
                    }

                    withTransaction(Transaction(animation: nil)) {
                        enemyStates[index].dying = true
                        enemyStates[index].deathStartDate = Date()
                    }

                    if isLastDyingStart {
                        let dropName = randomRoomDropImageName()
                        withTransaction(Transaction(animation: nil)) {
                            addRoomDropItemToInventory(assetImageName: dropName)
                            potionDropImageName = dropName
                            potionDropEnemyIndex = index
                        }
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + enemyDeathAnimationDuration) {
                        guard gameSessionId == sessionId else { return }
                        guard index < enemyStates.count else { return }
                        withTransaction(Transaction(animation: nil)) {
                            enemyStates[index].dead = true
                            enemyStates[index].dying = false
                            enemyStates[index].deathStartDate = nil
                        }

                        if isLastDyingStart {
                            withTransaction(Transaction(animation: nil)) {
                                potionDropEnemyIndex = nil
                                potionDropImageName = nil
                            }
                        }
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + groundEnd) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                bombGroundStartDate = nil
                isBombThrowActive = false
                bombThrowStartDate = nil
                bombTargetIndex = nil
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + unlockTime) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                isAttackInputLocked = false
            }
            maybeStartPendingEnemyAttack(forSession: sessionId)
        }
    }

    private func startKnifeThrow(targetIndex index: Int) {
        let sessionId = gameSessionId
        guard !isBombThrowActive else { return }
        guard !isKnifeThrowActive else { return }
        guard !isRogueWalking else { return }
        guard index >= 0, index < enemyStates.count else { return }
        guard !enemyStates[index].dead, !enemyStates[index].dying else { return }
        guard consumeThrowingKnifeStack() else {
            withTransaction(Transaction(animation: nil)) {
                inventoryEnemyTargetItem = nil
                inventoryCrownDetent = 0
            }
            return
        }

        withTransaction(Transaction(animation: nil)) {
            inventoryEnemyTargetItem = nil
            inventoryCrownDetent = 0
        }

        let throwStart = Date()
        withTransaction(Transaction(animation: nil)) {
            isKnifeThrowActive = true
            knifeThrowStartDate = throwStart
            knifeTargetIndex = index
            knifeProjectileStartDate = nil
            isAttackInputLocked = true
        }

        let projLaunch = Double(GameConstants.knifeProjectileLaunchFrame - 1) * GameConstants.knifeThrowFrameDuration
        let damageTime = projLaunch + GameConstants.knifeProjectileDuration
        let unlockTime = damageTime + enemyDamageDuration

        DispatchQueue.main.asyncAfter(deadline: .now() + projLaunch) {
            guard gameSessionId == sessionId else { return }
            guard isKnifeThrowActive else { return }
            withTransaction(Transaction(animation: nil)) {
                knifeProjectileStartDate = Date()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + damageTime) {
            guard gameSessionId == sessionId else { return }
            guard index < enemyStates.count else { return }
            guard !enemyStates[index].dead, !enemyStates[index].dying else { return }

            enemyStates[index].hitCount += 2

            withTransaction(Transaction(animation: nil)) {
                knifeProjectileStartDate = nil
                damagedEnemyIndex = index
                enemyDamageStartDate = Date()
                triggerEnemyHitFloat(forEnemyIndex: index, damageAmount: 2, showCritBang: false, startDate: Date(), forSession: sessionId)
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + enemyDamageDuration) {
                guard gameSessionId == sessionId else { return }
                guard index < enemyStates.count else { return }
                withTransaction(Transaction(animation: nil)) {
                    damagedEnemyIndex = nil
                    enemyDamageStartDate = nil
                }
                if enemyStates[index].hitCount >= enemyStates[index].hitsToKill, !enemyStates[index].dead, !enemyStates[index].dying {
                    let isLastDyingStart = enemyStates.enumerated().allSatisfy { (i, s) in
                        if i == index { return true }
                        return s.dead || s.dying
                    }

                    withTransaction(Transaction(animation: nil)) {
                        enemyStates[index].dying = true
                        enemyStates[index].deathStartDate = Date()
                    }

                    if isLastDyingStart {
                        let dropName = randomRoomDropImageName()
                        withTransaction(Transaction(animation: nil)) {
                            addRoomDropItemToInventory(assetImageName: dropName)
                            potionDropImageName = dropName
                            potionDropEnemyIndex = index
                        }
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + enemyDeathAnimationDuration) {
                        guard gameSessionId == sessionId else { return }
                        guard index < enemyStates.count else { return }
                        withTransaction(Transaction(animation: nil)) {
                            enemyStates[index].dead = true
                            enemyStates[index].dying = false
                            enemyStates[index].deathStartDate = nil
                        }

                        if isLastDyingStart {
                            withTransaction(Transaction(animation: nil)) {
                                potionDropEnemyIndex = nil
                                potionDropImageName = nil
                            }
                        }
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + unlockTime) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                isKnifeThrowActive = false
                knifeThrowStartDate = nil
                knifeTargetIndex = nil
                knifeProjectileStartDate = nil
                isAttackInputLocked = false
            }
            maybeStartPendingEnemyAttack(forSession: sessionId)
        }
    }

    private func startShurikenAttack() {
        let sessionId = gameSessionId
        guard !isBombThrowActive else { return }
        guard !isKnifeThrowActive else { return }
        guard !isShurikenActive else { return }
        guard !isRogueDead else { return }
        guard hasLivingEnemies else { return }
        guard manaRemaining > 0 else { return }

        let shurikenStart = Date()
        applyRogueAttackActionAdvancingEnemyTurns()
        withTransaction(Transaction(animation: nil)) {
            manaRemaining = max(0, manaRemaining - 1)
            showSkillSheet = false
            isShurikenActive = true
            shurikenStartDate = shurikenStart
            shurikenDamageApplied = false
            isAttackInputLocked = true
        }

        let damageDelay = Double(GameConstants.shurikenDamageFrame) * GameConstants.shurikenFrameDuration

        DispatchQueue.main.asyncAfter(deadline: .now() + damageDelay) {
            guard gameSessionId == sessionId else { return }
            guard !shurikenDamageApplied else { return }
            withTransaction(Transaction(animation: nil)) {
                shurikenDamageApplied = true
            }

            var killedIndices: [Int] = []
            var shurikenHadAnyCrit = false

            for i in 0..<enemyStates.count {
                guard !enemyStates[i].dead, !enemyStates[i].dying else { continue }
                
                let didCrit = Double.random(in: 0..<1) < GameConstants.rogueCriticalHitChance
                if didCrit {
                    shurikenHadAnyCrit = true
                }
                let dmg = didCrit ? 2 : 1
                enemyStates[i].hitCount += dmg
                triggerEnemyHitFloat(forEnemyIndex: i, damageAmount: dmg, showCritBang: didCrit, startDate: Date(), forSession: sessionId)

                if enemyStates[i].hitCount >= enemyStates[i].hitsToKill {
                    killedIndices.append(i)
                }
            }

            withTransaction(Transaction(animation: nil)) {
                damagedEnemyIndex = nil
                enemyDamageStartDate = Date()
                if shurikenHadAnyCrit {
                    playLightHeartLostHaptic()
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + enemyDamageDuration) {
                guard gameSessionId == sessionId else { return }
                withTransaction(Transaction(animation: nil)) {
                    enemyDamageStartDate = nil
                }

                if !killedIndices.isEmpty {
                    let allRemainingDie = enemyStates.enumerated().allSatisfy { (i, s) in
                        s.dead || s.dying || killedIndices.contains(i)
                    }
                    let potionDropIndex = allRemainingDie ? killedIndices.first : nil

                    for idx in killedIndices {
                        withTransaction(Transaction(animation: nil)) {
                            enemyStates[idx].dying = true
                            enemyStates[idx].deathStartDate = Date()
                        }
                    }

                    if let dropIdx = potionDropIndex {
                        let dropName = randomRoomDropImageName()
                        withTransaction(Transaction(animation: nil)) {
                            addRoomDropItemToInventory(assetImageName: dropName)
                            potionDropImageName = dropName
                            potionDropEnemyIndex = dropIdx
                        }
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + enemyDeathAnimationDuration) {
                        guard gameSessionId == sessionId else { return }
                        for idx in killedIndices {
                            withTransaction(Transaction(animation: nil)) {
                                enemyStates[idx].dead = true
                                enemyStates[idx].dying = false
                                enemyStates[idx].deathStartDate = nil
                            }
                        }

                        if potionDropIndex != nil {
                            withTransaction(Transaction(animation: nil)) {
                                potionDropEnemyIndex = nil
                                potionDropImageName = nil
                            }
                        }
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + GameConstants.shurikenDuration) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                isShurikenActive = false
                shurikenStartDate = nil
                shurikenDamageApplied = false
                isAttackInputLocked = false
            }
            maybeStartPendingEnemyAttack(forSession: sessionId)
        }
    }

    private func startRogueAttack(atPosition x: CGFloat, y: CGFloat, enemyIndex: Int?) {
        let sessionId = gameSessionId
        guard !isAttackInputLocked else { return }
        guard !isRogueWalking else { return }
        guard canTapEnemies else { return }
        guard let index = enemyIndex, index >= 0, index < enemyStates.count else { return }
        guard !enemyStates[index].dead else { return }
        
        let didCrit = Double.random(in: 0..<1) < GameConstants.rogueCriticalHitChance
        enemyStates[index].hitCount += didCrit ? 2 : 1
        applyRogueAttackActionAdvancingEnemyTurns()
        totalHitsUsed += 1
        withTransaction(Transaction(animation: nil)) {
            rogueOffsetX = x
            rogueOffsetY = y
            attackStartDate = Date()
            isRogueAttacking = true
            isAttackInputLocked = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + enemyDamageDelay) {
            guard gameSessionId == sessionId else { return }
            guard index < enemyStates.count else { return }
            withTransaction(Transaction(animation: nil)) {
                damagedEnemyIndex = index
                enemyDamageStartDate = Date()
                let dmg = didCrit ? 2 : 1
                if didCrit {
                    playLightHeartLostHaptic()
                }
                triggerEnemyHitFloat(forEnemyIndex: index, damageAmount: dmg, showCritBang: didCrit, startDate: Date(), forSession: sessionId)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + enemyDamageDelay + enemyDamageDuration) {
            guard gameSessionId == sessionId else { return }
            guard index < enemyStates.count else { return }
            withTransaction(Transaction(animation: nil)) {
                damagedEnemyIndex = nil
                enemyDamageStartDate = nil
            }
            if enemyStates[index].hitCount >= enemyStates[index].hitsToKill, !enemyStates[index].dead, !enemyStates[index].dying {
                // The "last enemy" is the one that enters its dying state last.
                let isLastDyingStart = enemyStates.enumerated().allSatisfy { (i, s) in
                    if i == index { return true }
                    return s.dead || s.dying
                }

                withTransaction(Transaction(animation: nil)) {
                    enemyStates[index].dying = true
                    enemyStates[index].deathStartDate = Date()
                }

                if isLastDyingStart {
                    let dropName = randomRoomDropImageName()
                    withTransaction(Transaction(animation: nil)) {
                        addRoomDropItemToInventory(assetImageName: dropName)
                        potionDropImageName = dropName
                        potionDropEnemyIndex = index
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + enemyDeathAnimationDuration) {
                    guard gameSessionId == sessionId else { return }
                    guard index < enemyStates.count else { return }
                    withTransaction(Transaction(animation: nil)) {
                        enemyStates[index].dead = true
                        enemyStates[index].dying = false
                        enemyStates[index].deathStartDate = nil
                    }

                    if isLastDyingStart {
                        withTransaction(Transaction(animation: nil)) {
                            guard gameSessionId == sessionId else { return }
                            potionDropEnemyIndex = nil
                            potionDropImageName = nil
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + enemyDamageDelay + enemyDamageDuration + postDamageTapCooldownDuration) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                isAttackInputLocked = false
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + rogueAttackDuration) {
            guard gameSessionId == sessionId else { return }
            withTransaction(Transaction(animation: nil)) {
                isRogueAttacking = false
                attackStartDate = nil
                rogueOffsetX = GameConstants.rogueIdleOffsetX
                rogueOffsetY = GameConstants.rogueIdleOffsetY
            }
            maybeStartPendingEnemyAttack(forSession: sessionId)
        }
    }

    var body: some View {
        ZStack {
            Group {
                switch rootScreen {
                case .title:
                    titleLandingView
                case .info:
                    infoScreenView
                case .loading:
#if os(watchOS)
                    gameLaunchLoadingScreen
#else
                    titleLandingView
#endif
                case .game:
                    gameplayRoot
                }
            }
#if os(watchOS)
            if isStartLoadingGame && rootScreen != .game {
                immediateStartFeedbackOverlay
                    .zIndex(500)
            }
#endif
        }
    }

    private var titleLandingView: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Spacer(minLength: 0)
                Text("Bit Battler")
                    .font(bitBattlerTitleFont)
                    .foregroundStyle(Color.red)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.55)
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                Spacer(minLength: 0)
                Button("Start") {
#if os(watchOS)
                    beginTransitionFromTitleToGame()
#else
                    DispatchQueue.main.async {
                        rootScreen = .game
                    }
#endif
                }
                .buttonStyle(.borderedProminent)
#if os(watchOS)
                .disabled(isStartLoadingGame)
#endif
                #if os(watchOS)
                PrewarmProgressBar(showsLabel: false, hideWhenComplete: true)
                    .frame(width: 110)
                #endif
                Spacer(minLength: 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button {
                rootScreen = .info
            } label: {
                Image(systemName: "info.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .padding(.top, 0)
            .padding(.trailing, 4)
            .offset(y: -10)
#if os(watchOS)
            .disabled(isStartLoadingGame)
            .opacity(isStartLoadingGame ? 0.35 : 1)
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
#if os(watchOS)
        ._statusBarHidden()
#endif
    }

#if os(watchOS)
    private var immediateStartFeedbackOverlay: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 8) {
                ProgressView()
                    .tint(.red)
                Text("Loading...")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.92))
            }
        }
        .allowsHitTesting(true)
    }

    private var gameLaunchLoadingScreen: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 12) {
                PrewarmProgressBar(showsLabel: true, hideWhenComplete: false)
                    .frame(width: 128)
                Text("Loading...")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.92))
            }
            .padding(.horizontal, 20)
        }
        .allowsHitTesting(true)
        ._statusBarHidden()
        .onAppear {
            DispatchQueue.main.async {
                continueFromLoadingScreenWhenPrewarmCompletes()
            }
        }
    }
#endif

    private var infoScreenView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pixel art by Krishna Palacio")
                        .font(.caption)
                        .foregroundStyle(.primary)
                    Text("Copyright Oh Hey Digital 2026")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .navigationTitle("Info")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Back") {
                        rootScreen = .title
                    }
                }
            }
        }
#if os(watchOS)
        ._statusBarHidden()
#endif
    }

    private var gameplayRoot: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
#if os(watchOS)
            ._statusBarHidden()
#endif
            .overlay {
                GameOverlaysView(
                    damagedEnemyIndex: damagedEnemyIndex,
                    enemyDamageStartDate: enemyDamageStartDate,
                    rogueOffsetX: rogueOffsetX,
                    rogueOffsetY: rogueOffsetY,
                    heartsRemaining: heartsRemaining,
                    manaRemaining: manaRemaining,
                    isRogueDead: isRogueDead,
                    rogueDamageStartDate: rogueDamageStartDate,
                    rogueDieStartDate: rogueDieStartDate,
                    rogueDodgeStartDate: rogueDodgeStartDate,
                    isEnemyAttackSequenceInProgress: isEnemyAttackSequenceInProgress,
                    activeEnemyAttackingIndex: activeEnemyAttackingIndex,
                    activeEnemyAttackStartDate: activeEnemyAttackStartDate,
                    isRogueAttacking: isRogueAttacking,
                    isAttackInputLocked: isAttackInputLocked,
                    attackStartDate: attackStartDate,
                    isRogueWalking: isRogueWalking,
                    walkStartDate: walkStartDate,
                    isRoomWiping: isRoomWiping,
                    roomWipeProgress: roomWipeProgress,
                    roomNumber: roomNumber,
                    isTrollWave: isTrollWave,
                    isSlimeWave: isSlimeWave,
                    isCyclopsWave: isCyclopsWave,
                    enemyCount: enemyCount,
                    enemyStates: enemyStates,
                    enemyHitFloatStates: enemyHitFloatStates,
                    canTapEnemies: canTapEnemies,
                    isShurikenActive: isShurikenActive,
                    shurikenStartDate: shurikenStartDate,
                    potionDropEnemyIndex: potionDropEnemyIndex,
                    potionDropImageName: potionDropImageName,
                    healEffectStartDate: healEffectStartDate,
                    manaRestoreEffectStartDate: manaRestoreEffectStartDate,
                    isInventoryEnemyTargetSelectionActive: isInventoryEnemyTargetSelectionActive,
                    isBombThrowActive: isBombThrowActive,
                    bombThrowStartDate: bombThrowStartDate,
                    bombTargetIndex: bombTargetIndex,
                    bombProjectileStartDate: bombProjectileStartDate,
                    bombGroundStartDate: bombGroundStartDate,
                    isKnifeThrowActive: isKnifeThrowActive,
                    knifeThrowStartDate: knifeThrowStartDate,
                    knifeTargetIndex: knifeTargetIndex,
                    knifeProjectileStartDate: knifeProjectileStartDate,
                    touchTargetSize: max(GameConstants.spriteFrameSize * 0.28125, GameConstants.minTouchTargetSize),
                    onEnemyTap: { index in
                        if let mode = inventoryEnemyTargetItem {
                            switch mode {
                            case .bomb:
                                startBombThrow(targetIndex: index)
                            case .throwingKnife:
                                startKnifeThrow(targetIndex: index)
                            }
                            return
                        }
                        let pos = enemyPosition(index: index)
                        startRogueAttack(
                            atPosition: pos.x - GameConstants.spriteFrameSize - GameConstants.rogueEnemyGap + GameConstants.rogueAttackOffsetX,
                            y: pos.y,
                            enemyIndex: index
                        )
                    },
                    onRogueTap: {
                        if canTapEnemies && !isRogueAttacking && !isAttackInputLocked && !isRogueWalking && !isBombThrowActive && !isKnifeThrowActive && !isInventoryEnemyTargetSelectionActive {
                            showSkillSheet = true
                        }
                    },
                    onRogueLongPress: { showResetConfirmation = true },
                    onNextWaveTap: { arrowX, arrowY in
                        startRogueWalkToNextWave(arrowOffsetX: arrowX, arrowOffsetY: arrowY)
                    }
                )
                // Visual nudge for the playfield only — must not apply to full-screen menus or they won’t cover the full display.
                .offset(y: -9)
#if os(watchOS)
                // Playfield focus steals Digital Crown / gesture routing from full-screen menus that sit above it.
                // Turn it off whenever a menu or modal is up — including Items (`inventoryCrownDetent > 0.5`).
                .focusable(!(
                    showSkillSheet
                        || showGameOverPopup
                        || itemOrSkillDetail != nil
                        || inventoryCrownDetent > 0.5
                ))
#endif
            }
            .overlay {
                // Hide Items while choosing a bomb/knife target so the crown/detent binding can’t leave both UIs up.
                if inventoryCrownDetent > 0.5 && !isInventoryEnemyTargetSelectionActive && !suppressItemsMenuOverlay {
                    FullScreenMenuSheet(title: "Items") {
                        dismissItemsMenu()
                    } content: {
                        inventorySheetScrollContent
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .all)
                    .zIndex(2000)
                    .allowsHitTesting(true)
                }
            }
            .overlay {
                if showSkillSheet {
                    FullScreenMenuSheet(title: "Skills") {
                        withTransaction(Transaction(animation: nil)) {
                            showSkillSheet = false
                        }
                    } content: {
                        ScrollView(.vertical) {
                            VStack(spacing: 8) {
                                Button("Shuriken") {
                                    if manaSkillsUnavailableOnlyDueToMana {
                                        presentSkillToast("Not enough mana")
                                        return
                                    }
                                    guard canUseManaSkills else { return }
                                    startShurikenAttack()
                                }
                                .buttonStyle(.bordered)
                                .opacity(canUseManaSkills ? 1 : 0.45)
                                .highPriorityGesture(
                                    LongPressGesture(minimumDuration: 0.45)
                                        .onEnded { _ in
                                            if let desc = InventoryItemAndSkillDescriptions.description(forSkill: "Shuriken") {
                                                itemOrSkillDetail = ItemOrSkillDetailPayload(title: "Shuriken", description: desc)
                                            }
                                        }
                                )
                                Button("Bomb") {
                                    if manaSkillsUnavailableOnlyDueToMana {
                                        presentSkillToast("Not enough mana")
                                        return
                                    }
                                    guard canUseManaSkills else { return }
                                    withTransaction(Transaction(animation: nil)) {
                                        showSkillSheet = false
                                        inventoryEnemyTargetItem = .bomb
                                    }
                                }
                                .buttonStyle(.bordered)
                                .opacity(canUseManaSkills ? 1 : 0.45)
                                .highPriorityGesture(
                                    LongPressGesture(minimumDuration: 0.45)
                                        .onEnded { _ in
                                            if let desc = InventoryItemAndSkillDescriptions.description(forSkill: "Bomb") {
                                                itemOrSkillDetail = ItemOrSkillDetailPayload(title: "Bomb", description: desc)
                                            }
                                        }
                                )
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .all)
                    .zIndex(3000)
                    .allowsHitTesting(true)
                }
            }
            .overlay(alignment: .bottom) {
                if let msg = skillToastMessage {
                    Text(msg)
                        .font(.caption2.bold())
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(.bottom, 6)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .overlay {
                if let detail = itemOrSkillDetail {
                    ItemOrSkillDetailOverlay(
                        title: detail.title,
                        description: detail.description,
                        onBack: { itemOrSkillDetail = nil }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .all)
                    .zIndex(4000)
                    .allowsHitTesting(true)
                }
            }
            // Bomb skill / Throwing Knife item target prompt: thin top bar only (no full-screen scrim) so enemies stay tappable.
            .overlay(alignment: .top) {
                if isInventoryEnemyTargetSelectionActive {
                    HStack(spacing: 6) {
                        Text("Select target")
                            .font(.caption2.bold())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            withTransaction(Transaction(animation: nil)) {
                                inventoryEnemyTargetItem = nil
                                inventoryCrownDetent = 0
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(Color.primary.opacity(0.12))
                                    .frame(width: 23, height: 23)
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.primary)
                            }
                            .frame(width: 29, height: 29)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .offset(y: -24)
                    .zIndex(3500)
                }
            }
            .overlay {
                if showGameOverPopup {
                    ZStack {
                        Color.black.opacity(0.65)
                            .ignoresSafeArea()

                        VStack(spacing: 12) {
                            Text("Game Over")
                                .font(.headline)
                                .foregroundStyle(.primary)

                            Button("Continue") {
                                returnToTitleScreenResettingGame()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 18)
                    }
                    .allowsHitTesting(true)
                    .zIndex(5000)
                }
            }
            .onAppear {
                if enemyStates.isEmpty {
                    resetEnemies()
                }
            }
#if os(watchOS)
            .digitalCrownRotation(
                detent: $inventoryCrownDetent,
                from: 0,
                through: 1,
                by: 1,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onChange(of: showSkillSheet) { _, newValue in
                if !newValue {
                    itemOrSkillDetail = nil
                }
            }
            .onChange(of: inventoryCrownDetent) { oldValue, newValue in
                if oldValue >= 0.5, newValue < 0.5 {
                    itemOrSkillDetail = nil
                }
                if !isInventoryEnemyTargetSelectionActive {
                    if newValue < 0.5 {
                        suppressItemsMenuOverlay = false
                    } else if newValue > oldValue, newValue > 0.5 {
                        suppressItemsMenuOverlay = false
                    }
                }
                // During bomb/knife target picking, cancel when the crown moves off “closed” (user interaction).
                // Ignore settles to 0 (e.g. late 1→0 after closing Items) — those used to clear
                // targeting immediately because targeting mode flipped on inside that window.
                guard isInventoryEnemyTargetSelectionActive else { return }
                guard newValue > 0.05 else { return }
                withTransaction(Transaction(animation: nil)) {
                    inventoryEnemyTargetItem = nil
                    inventoryCrownDetent = 0
                }
            }
#endif
            .confirmationDialog("Reset Game?", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) {
                    withTransaction(Transaction(animation: nil)) {
                        resetGameToInitialState()
                    }
                }
                Button("Cancel", role: .cancel) {
                    showResetConfirmation = false
                }
            } message: {
                Text("Restore all enemies and reset hit counts?")
            }
    }

    @ViewBuilder
    private var inventorySheetScrollContent: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                if inventoryStacks.isEmpty {
                    Text("No items")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(inventoryStacks) { stack in
                        Button(inventoryStackButtonLabel(stack)) {
                            switch stack.displayName {
                            case "Sm Health Pot":
                                guard inventoryStackAppearsUsable(stack) else { return }
                                dismissItemsMenu()
                                let sessionIdSnapshot = gameSessionId
                                withTransaction(Transaction(animation: nil)) {
                                    isInventoryConsumePending = true
                                }
                                let closeDelay: Double = 0.25
                                DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay) {
                                    withTransaction(Transaction(animation: nil)) {
                                        consumeSmallHealthPotionStack()
                                        startHealEffect(forSession: sessionIdSnapshot)
                                        isInventoryConsumePending = false
                                    }
                                }
                            case "Sm Mana Pot":
                                guard inventoryStackAppearsUsable(stack) else { return }
                                dismissItemsMenu()
                                let sessionIdSnapshot = gameSessionId
                                withTransaction(Transaction(animation: nil)) {
                                    isInventoryConsumePending = true
                                }
                                let closeDelay: Double = 0.25
                                DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay) {
                                    withTransaction(Transaction(animation: nil)) {
                                        consumeSmallManaPotionStack()
                                        startManaRestoreEffect(forSession: sessionIdSnapshot)
                                        isInventoryConsumePending = false
                                    }
                                }
                            case "Throwing Knife":
                                guard canConsumeItems && hasLivingEnemies && stack.count > 0 else { return }
                                dismissItemsMenu()
                                let sessionIdSnapshot = gameSessionId
                                let closeDelay: Double = 0.25
                                DispatchQueue.main.asyncAfter(deadline: .now() + closeDelay) {
                                    guard gameSessionId == sessionIdSnapshot else { return }
                                    withTransaction(Transaction(animation: nil)) {
                                        inventoryEnemyTargetItem = .throwingKnife
                                    }
                                }
                            default:
                                break
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isInventoryConsumePending)
                        .opacity(inventoryStackAppearsUsable(stack) ? 1 : 0.45)
                        .highPriorityGesture(
                            LongPressGesture(minimumDuration: 0.45)
                                .onEnded { _ in
                                    if let desc = InventoryItemAndSkillDescriptions.description(forInventoryItem: stack.displayName) {
                                        itemOrSkillDetail = ItemOrSkillDetailPayload(title: stack.displayName, description: desc)
                                    }
                                }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }
}

// Detail screen for long-press on an item or skill row: name, description, Back to list.
private struct ItemOrSkillDetailOverlay: View {
    let title: String
    let description: String
    let onBack: () -> Void

    var body: some View {
        GeometryReader { geo in
            let topPad = max(14, geo.safeAreaInsets.top + 6)
            let headerReserve = topPad + 54

            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.black.opacity(0.52))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(true)

                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: headerReserve)
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .background(.ultraThinMaterial)

                HStack(alignment: .center, spacing: 8) {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 10, weight: .bold))
                            Text("Back")
                                .font(.caption2.bold())
                        }
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 1, x: 0, y: 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, topPad)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background {
                    ZStack {
                        Rectangle().fill(Color.black.opacity(0.12))
                        Rectangle().fill(.ultraThinMaterial)
                    }
                }
                .zIndex(20)
                .allowsHitTesting(true)
            }
        }
        .ignoresSafeArea(edges: .all)
    }
}

// Full-screen menu (Skills + Items): matches `Room` label typography; X closes.
private struct FullScreenMenuSheet<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        GeometryReader { geo in
            let topPad = max(14, geo.safeAreaInsets.top + 6)
            // Reserve space so scroll content doesn’t sit under the pinned header; matches header paddings + ~44pt control.
            let headerReserve = topPad + 54

            ZStack(alignment: .top) {
                // Full-rect scrim (watch: safe areas included) so underlying “Room” etc. is fully covered.
                Rectangle()
                    .fill(Color.black.opacity(0.52))
                    .frame(width: geo.size.width, height: geo.size.height)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    .allowsHitTesting(true)

                VStack(spacing: 0) {
                    // Invisible spacer: same height as the floating header so `ScrollView` layout matches hit-testing.
                    Color.clear
                        .frame(height: headerReserve)
                    content()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                .background(.ultraThinMaterial)

                // Pinned above scroll layer so watchOS doesn’t route taps into `ScrollView` / material edge cases.
                HStack(alignment: .center, spacing: 8) {
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.85), radius: 1, x: 0, y: 1)
                    Spacer(minLength: 0)
                    Button(action: onClose) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.22))
                                .frame(width: 28, height: 28)
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        // HIG-friendly target; explicit shape so the whole square receives taps.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 14)
                .padding(.top, topPad)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, alignment: .top)
                .background {
                    ZStack {
                        Rectangle().fill(Color.black.opacity(0.12))
                        Rectangle().fill(.ultraThinMaterial)
                    }
                }
                .zIndex(20)
                .allowsHitTesting(true)
            }
        }
        .ignoresSafeArea(edges: .all)
#if os(watchOS)
        // Prefer the menu (not the playfield under it) for crown / touch routing when this sheet is visible.
        .focusable(true)
#endif
    }
}

// MARK: - Game constants (in same file so type is in scope for IDE)
enum GameConstants {
    static let spriteFrameCount = 8
    static let spriteFrameDuration: Double = 0.4
    static let attackFrameCount = 4
    static let attackFrameDuration: Double = 0.1
    // Enemy attack sprites are tuned independently from the rogue.
    static let enemyAttackFrameCount = attackFrameCount
    // 10% faster than the previous enemy tuning (was 1.25x the base).
    static let enemyAttackFrameDuration: Double = attackFrameDuration * (1.25 * 0.9)
    static let rogueDodgeFrameCount: Int = 5
    /// Matches the current enemy "translation window" for misses.
    static let rogueDodgeAnimationDuration: Double = Double(enemyAttackFrameCount) * enemyAttackFrameDuration
    static let rogueDodgeFrameDuration: Double = rogueDodgeAnimationDuration / Double(rogueDodgeFrameCount)
    static let deathAnimationDuration: Double = 1.5
    static let roomWipeDuration: Double = 0.5
    /// First room shown when starting or after a full reset.
    static let startingRoomNumber = 1
    static let walkFrameCount = 4
    static let walkFrameDuration: Double = 0.1
    static let rogueWalkSpeedPointsPerSecond: Double = 220
    static let rogueWalkTranslationStepPx: CGFloat = 3
    static let assetScale: CGFloat = 1.5
    static let spriteFrameSize: CGFloat = 64 * 1.5  // 96, matches 1.5x resized assets
    static let minTouchTargetSize: CGFloat = 44
    static let rogueIdleOffsetX: CGFloat = -33
    static let rogueIdleOffsetY: CGFloat = 24
    static let rogueEnemyGap: CGFloat = 8
    static let rogueAttackOffsetX: CGFloat = 75
    static let heartsInitial: Int = 5
    static let manaInitial: Int = 1
    // Healing potion effect (8-frame sprite sheet).
    static let healSpriteFrameSize: CGFloat = 64
    static let healFrameCount = 8
    static let healEffectDuration: Double = 0.8
    static let healFrameDuration: Double = healEffectDuration / Double(healFrameCount)
    /// Renders the heal effect `18px` above the rogue position.
    static let healEffectYOffset: CGFloat = 18
    // Mana restore effect (8-frame sprite sheet).
    static let manaRestoreFrameCount = 8
    static let manaRestoreEffectDuration: Double = 0.8
    static let manaRestoreFrameDuration: Double = manaRestoreEffectDuration / Double(manaRestoreFrameCount)
    static let manaRestoreEffectYOffset: CGFloat = 18
    static let rogueHitKnockbackPx: CGFloat = 3
    static let rogueMissDodgeKnockbackPx: CGFloat = 24
    static let rogueDodgeTranslationStepPx: CGFloat = 3
    /// < 1 means the Rogue slides left faster than the dodge window duration.
    static let rogueDodgeTranslationDurationMultiplier: Double = 0.6
    /// Enemy ends up `enemyToRogueSpacingPx` to the right of the rogue during an attack.
    static let enemyToRogueSpacingPx: CGFloat = spriteFrameSize + rogueEnemyGap - rogueAttackOffsetX

    static let rogueDamageFrameCount = 4
    static let rogueDieFrameCount = 26
    static let rogueDamageFrameDuration: Double = attackFrameDuration
    // Slower death animation for readability.
    static let rogueDieAnimationDuration: Double = (deathAnimationDuration * 1.25) + 0.5
    static let rogueDieFrameDuration: Double = rogueDieAnimationDuration / Double(rogueDieFrameCount)

    static let shurikenFrameCount: Int = 15
    static let shurikenDuration: Double = 1.5
    static let shurikenFrameDuration: Double = shurikenDuration / Double(shurikenFrameCount)
    /// Damage lands at frame 10 (0-indexed: after 10 frames have elapsed).
    static let shurikenDamageFrame: Int = 10

    static let rogueAttacksPerEnemyAttackCycle: Int = 3

    // Bomb throw / explosion (spritesheets).
    static let bombThrowFrameCount: Int = 11
    static let bombThrowFrameDuration: Double = 0.1
    /// 1-based frame index: projectile starts on frame 8.
    static let bombProjectileLaunchFrame: Int = 8
    static let bombProjectileDuration: Double = 0.3
    /// In-flight `BombThrown` strip (2 frames); advances to the next frame every 200ms.
    static let bombThrownFrameCount: Int = 2
    static let bombThrownFrameDuration: Double = 0.2
    static let bombGroundFrameCount: Int = 11
    static let bombGroundDuration: Double = 1.1
    static let bombGroundFrameDuration: Double = bombGroundDuration / Double(bombGroundFrameCount)
    /// 1-based frame index for damage during `BombGround`.
    static let bombGroundDamageFrame: Int = 10

    // Throwing Knife (rogue toss + `KnifeThrown` flight).
    static let knifeThrowFrameCount: Int = 5
    static let knifeThrowDuration: Double = 0.5
    static let knifeThrowFrameDuration: Double = knifeThrowDuration / Double(knifeThrowFrameCount)
    /// 1-based frame index: projectile starts on the 5th frame of `RogueKnifeThrow`.
    static let knifeProjectileLaunchFrame: Int = 5
    static let knifeProjectileDuration: Double = 0.4
    static let knifeThrownFrameCount: Int = 4
    static let knifeThrownFrameDuration: Double = knifeProjectileDuration / Double(knifeThrownFrameCount)
    /// In-world offset from rogue anchor to knife spawn (px).
    static let knifeSpawnOffsetX: CGFloat = 6
    
    // Rogue critical hits.
    static let rogueCriticalHitChance: Double = 0.16 // 16%
    
    // Floating crit text animation.
    static let critTextDuration: Double = 1.0
    // Starts 9px above the enemy sprite center.
    // Starts above the enemy sprite center (negative = up).
    static let critTextBaseYOffset: CGFloat = -15
    static let critTextTranslateUpPx: CGFloat = 15
    static let enemyAttackPreDelay: Double = 0.25
}

/// Per-enemy combat state for the current wave.
struct EnemyState {
    var hitCount: Int
    var hitsToKill: Int
    var dead: Bool
    var dying: Bool
    var deathStartDate: Date?
    /// Counts down each rogue attack action (melee / shuriken / bomb). Throwing Knife does not decrement this. At `<= 0`, this enemy is eligible to retaliate.
    var rogueAttacksUntilEnemyTurn: Int
}

private struct InventoryStack: Identifiable, Equatable {
    var displayName: String
    var count: Int
    var id: String { displayName }
}

// MARK: - GameOverlaysView subtrees (smaller bodies = cheaper SwiftUI diffing on watchOS)

private struct GameOverlaysRoomTorchesLayer: View {
    let roomNumber: Int

    var body: some View {
        ZStack {
            Image("Room")
                .interpolation(.none)

            VStack(spacing: 0) {
                Spacer()
                Text("Room \(roomNumber)")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.85), radius: 1, x: 0, y: 1)
                    .padding(.bottom, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(0.5)

            TorchView(offsetX: -42, offsetY: -33)
            TorchView(offsetX: 45, offsetY: -33)
        }
    }
}

private struct GameOverlaysHeartsHUD: View {
    let heartsRemaining: Int
    @State private var removingHeartSlots: Set<Int> = []
    @State private var removingHeartStep: [Int: Double] = [:]

    var body: some View {
        VStack {
            HStack(spacing: 2) {
                ForEach(0..<GameConstants.heartsInitial, id: \.self) { idx in
                    let progress = removingHeartStep[idx] ?? 0
                    Image("Heart")
                        .resizable()
                        .frame(width: 14, height: 14)
                        .opacity({
                            if idx < heartsRemaining { return 1 }
                            if removingHeartSlots.contains(idx) {
                                return max(0, min(1, 1 - progress))
                            }
                            return 0
                        }())
                        .offset(y: {
                            guard removingHeartSlots.contains(idx) else { return 0 }
                            return -CGFloat(progress) * 15
                        }())
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 4)
            .padding(.top, 4)
            .offset(x: 37, y: 31)
            .onChange(of: heartsRemaining) { oldValue, newValue in
                guard newValue < oldValue else {
                    removingHeartSlots.removeAll()
                    removingHeartStep.removeAll()
                    return
                }
                let removedSlots = (newValue..<oldValue).reversed()
                for removedIdx in removedSlots where removedIdx >= 0 && removedIdx < GameConstants.heartsInitial {
                    removingHeartSlots.insert(removedIdx)
                    removingHeartStep[removedIdx] = 0
                    withAnimation(.linear(duration: 0.5)) {
                        removingHeartStep[removedIdx] = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        removingHeartSlots.remove(removedIdx)
                        removingHeartStep.removeValue(forKey: removedIdx)
                    }
                }
            }

            Spacer()
        }
    }
}

private struct GameOverlaysManaHUD: View {
    let manaRemaining: Int
    @State private var removingManaSlots: Set<Int> = []
    @State private var removingManaStep: [Int: Double] = [:]

    var body: some View {
        VStack {
            HStack(spacing: 2) {
                Spacer()
                ForEach((0..<GameConstants.manaInitial).reversed(), id: \.self) { idx in
                    let progress = removingManaStep[idx] ?? 0
                    Image("Mana")
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 14, height: 14)
                        .opacity({
                            if idx < manaRemaining { return 1 }
                            if removingManaSlots.contains(idx) {
                                return max(0, min(1, 1 - progress))
                            }
                            return 0
                        }())
                        .offset(y: {
                            guard removingManaSlots.contains(idx) else { return 0 }
                            return -CGFloat(progress) * 15
                        }())
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 4)
            .padding(.top, 4)
            .offset(x: -37, y: 31)
            .onChange(of: manaRemaining) { oldValue, newValue in
                guard newValue < oldValue else {
                    removingManaSlots.removeAll()
                    removingManaStep.removeAll()
                    return
                }
                let removedSlots = (newValue..<oldValue).reversed()
                for removedIdx in removedSlots where removedIdx >= 0 && removedIdx < GameConstants.manaInitial {
                    removingManaSlots.insert(removedIdx)
                    removingManaStep[removedIdx] = 0
                    withAnimation(.linear(duration: 0.5)) {
                        removingManaStep[removedIdx] = 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        removingManaSlots.remove(removedIdx)
                        removingManaStep.removeValue(forKey: removedIdx)
                    }
                }
            }

            Spacer()
        }
    }
}

private struct GameOverlaysEnemySpritesGrid: View {
    let enemyWaveProfile: EnemyWaveProfile
    let enemyCount: Int
    let enemyStates: [EnemyState]
    let enemyHitFloatStates: [Int: EnemyHitFloatState]
    let damagedEnemyIndex: Int?
    let enemyDamageStartDate: Date?
    let isShurikenActive: Bool
    let activeEnemyAttackingIndex: Int?
    let activeEnemyAttackStartDate: Date?
    let rogueOffsetX: CGFloat
    let rogueOffsetY: CGFloat
    let potionDropEnemyIndex: Int?
    let potionDropImageName: String?

    var body: some View {
        ForEach([0, 1, 2, 3], id: \.self) { (index: Int) in
            let pos = enemyWaveProfile.position(index: index, enemyCount: enemyCount)
            let fallbackHitsToKill = enemyWaveProfile.hitsToKill
            let enemySprites = enemyWaveProfile.spriteNames
            let state = index < enemyStates.count ? enemyStates[index] : EnemyState(hitCount: 0, hitsToKill: fallbackHitsToKill, dead: true, dying: false, deathStartDate: nil, rogueAttacksUntilEnemyTurn: 0)
            if !state.dead {
                ZStack {
                    if state.dying {
                        EnemyDeathView(
                            name: enemySprites.death,
                            frameCount: enemyWaveProfile.deathStripFrameCount,
                            deathStartDate: state.deathStartDate,
                            offsetX: pos.x,
                            offsetY: pos.y,
                            potionDropImageName: potionDropEnemyIndex == index ? potionDropImageName : nil
                        )
                    } else {
                        EnemySpriteView(
                            isAttacking: activeEnemyAttackingIndex == index,
                            enemyAttackStartDate: activeEnemyAttackStartDate,
                            attackName: enemySprites.attack,
                            rogueOffsetX: rogueOffsetX,
                            rogueOffsetY: rogueOffsetY,
                            attackOffsetXAdjustment: enemyWaveProfile.attackOffsetXAdjustment,
                            isDamaged: damagedEnemyIndex == index || (isShurikenActive && enemyDamageStartDate != nil),
                            enemyDamageStartDate: enemyDamageStartDate,
                            offsetX: pos.x,
                            offsetY: pos.y,
                            idleStartFrame: enemyWaveProfile.usesPrimarySlotIdleStartFrames ? (index < EnemiesConstants.primarySlotEnemyIdleStartFrames.count ? EnemiesConstants.primarySlotEnemyIdleStartFrames[index] : 0) : nil,
                            idleName: enemySprites.idle,
                            damageName: enemySprites.damage
                        )
                    }

                    if let hitFloat = enemyHitFloatStates[index] {
                        HitFloatTextView(
                            damageAmount: hitFloat.damageAmount,
                            showCritBang: hitFloat.showCritBang,
                            startDate: hitFloat.startDate
                        )
                        .offset(x: pos.x + 3, y: pos.y)
                    }
                }
                .zIndex(state.dying ? 2 : (activeEnemyAttackingIndex == index ? 3 : 2))
            }
        }
    }
}

private struct GameOverlaysRogueAndProjectileLayer: View {
    let isRogueDead: Bool
    let isRogueAttacking: Bool
    let attackStartDate: Date?
    let isRogueWalking: Bool
    let walkStartDate: Date?
    let rogueDamageStartDate: Date?
    let rogueDieStartDate: Date?
    let rogueDodgeStartDate: Date?
    let isBombThrowActive: Bool
    let bombThrowStartDate: Date?
    let isKnifeThrowActive: Bool
    let knifeThrowStartDate: Date?
    let isShurikenActive: Bool
    let shurikenStartDate: Date?
    let rogueOffsetX: CGFloat
    let rogueOffsetY: CGFloat
    let healEffectStartDate: Date?
    let manaRestoreEffectStartDate: Date?
    let isBombThrowActiveForGround: Bool
    let bombProjectileStartDate: Date?
    let bombGroundStartDate: Date?
    let bombTargetIndex: Int?
    let isKnifeThrowActiveForProj: Bool
    let knifeProjectileStartDate: Date?
    let knifeTargetIndex: Int?
    let slotPosition: (Int) -> (x: CGFloat, y: CGFloat)

    var body: some View {
        Group {
            if !isRogueDead {
                RogueSpriteOverlay(
                    isAttacking: isRogueAttacking,
                    attackStartDate: attackStartDate,
                    isWalking: isRogueWalking,
                    walkStartDate: walkStartDate,
                    rogueDamageStartDate: rogueDamageStartDate,
                    rogueDieStartDate: rogueDieStartDate,
                    rogueDodgeStartDate: rogueDodgeStartDate,
                    isBombThrowActive: isBombThrowActive,
                    bombThrowStartDate: bombThrowStartDate,
                    isKnifeThrowActive: isKnifeThrowActive,
                    knifeThrowStartDate: knifeThrowStartDate,
                    isShurikenActive: isShurikenActive,
                    shurikenStartDate: shurikenStartDate,
                    offsetX: rogueOffsetX,
                    offsetY: rogueOffsetY
                )
                .zIndex((isRogueAttacking || isShurikenActive || isBombThrowActive || isKnifeThrowActive) ? 3 : 1)

                if let healStart = healEffectStartDate {
                    HealEffectView(
                        startDate: healStart,
                        offsetX: rogueOffsetX,
                        offsetY: rogueOffsetY
                    )
                    .zIndex(4)
                }

                if let manaStart = manaRestoreEffectStartDate {
                    ManaRestoreEffectView(
                        startDate: manaStart,
                        offsetX: rogueOffsetX,
                        offsetY: rogueOffsetY
                    )
                    .zIndex(4)
                }
            }

            if isBombThrowActiveForGround, let bProjStart = bombProjectileStartDate, let bTIdx = bombTargetIndex {
                let destBomb = slotPosition(bTIdx)
                BombThrownFlightView(
                    startDate: bProjStart,
                    duration: GameConstants.bombProjectileDuration,
                    fromX: rogueOffsetX,
                    fromY: rogueOffsetY,
                    toX: destBomb.x,
                    toY: destBomb.y
                )
                .zIndex(8)
            }

            if isBombThrowActiveForGround, let bGroundStart = bombGroundStartDate, let bTIdx = bombTargetIndex {
                let gPos = slotPosition(bTIdx)
                TimelineView(.animation(minimumInterval: GameConstants.bombGroundFrameDuration)) { context in
                    SpriteSheetView(
                        name: "BombGround",
                        frameCount: GameConstants.bombGroundFrameCount,
                        date: context.date,
                        animationStartDate: bGroundStart,
                        frameDuration: GameConstants.bombGroundFrameDuration,
                        loopAnimation: false
                    )
                }
                .frame(width: GameConstants.spriteFrameSize, height: GameConstants.spriteFrameSize)
                .offset(x: gPos.x, y: gPos.y)
                .zIndex(7)
            }

            if isKnifeThrowActiveForProj, let kProjStart = knifeProjectileStartDate, let kTIdx = knifeTargetIndex {
                let destKnife = slotPosition(kTIdx)
                KnifeThrownFlightView(
                    startDate: kProjStart,
                    duration: GameConstants.knifeProjectileDuration,
                    fromX: rogueOffsetX + GameConstants.knifeSpawnOffsetX,
                    fromY: rogueOffsetY,
                    toX: destKnife.x,
                    toY: destKnife.y
                )
                .zIndex(8)
            }
        }
    }
}

private struct GameOverlaysTouchLayer: View {
    let enemyWaveProfile: EnemyWaveProfile
    let enemyCount: Int
    let enemyStates: [EnemyState]
    let touchTargetSize: CGFloat
    let rogueOffsetX: CGFloat
    let rogueOffsetY: CGFloat
    let isAttackInputLocked: Bool
    let isRogueWalking: Bool
    let canTapEnemies: Bool
    let isInventoryEnemyTargetSelectionActive: Bool
    let isBombThrowActive: Bool
    let isKnifeThrowActive: Bool
    let onEnemyTap: (Int) -> Void
    let onRogueTap: () -> Void
    let onRogueLongPress: () -> Void

    var body: some View {
        GeometryReader { geo in
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            ZStack {
                ForEach([0, 1, 2, 3], id: \.self) { (index: Int) in
                    let pos = enemyWaveProfile.position(index: index, enemyCount: enemyCount)
                    let fallbackHitsToKill = enemyWaveProfile.hitsToKill
                    let state = index < enemyStates.count ? enemyStates[index] : EnemyState(hitCount: fallbackHitsToKill, hitsToKill: fallbackHitsToKill, dead: true, dying: false, deathStartDate: nil, rogueAttacksUntilEnemyTurn: 0)
                    if !state.dead, !state.dying {
                        Button(action: { onEnemyTap(index) }) {
                            Color.white.opacity(0.01)
                        }
                        .buttonStyle(.plain)
                        .frame(width: touchTargetSize, height: touchTargetSize)
                        .contentShape(Rectangle())
                        .position(x: cx + pos.x, y: cy + pos.y)
                        .disabled({
                            if isInventoryEnemyTargetSelectionActive {
                                return isAttackInputLocked || isRogueWalking || state.hitCount >= state.hitsToKill || isBombThrowActive || isKnifeThrowActive
                            }
                            return isAttackInputLocked || isRogueWalking || state.hitCount >= state.hitsToKill || !canTapEnemies
                        }())
                        .accessibilityLabel(enemyWaveProfile.accessibilityLabel(enemyIndex: index))
                        .accessibilityHint("Tap to attack")
                    }
                }
                Color.white.opacity(0.01)
                    .frame(width: touchTargetSize, height: touchTargetSize)
                    .contentShape(Rectangle())
                    .position(x: cx + rogueOffsetX, y: cy + rogueOffsetY)
                    .onTapGesture {
                        onRogueTap()
                    }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        onRogueLongPress()
                    }
                    .accessibilityLabel("Rogue")
                    .accessibilityHint("Tap for skills, long press to reset game")
            }
        }
        .allowsHitTesting(true)
    }
}

private struct GameOverlaysNextWaveArrowLayer: View {
    @Binding var nextWaveArrowAnimationStartDate: Date
    let enemyCount: Int
    let enemyStates: [EnemyState]
    let isRogueWalking: Bool
    let isRogueAttacking: Bool
    let isEnemyAttackSequenceInProgress: Bool
    let isRogueDead: Bool
    let rogueDamageStartDate: Date?
    let rogueDieStartDate: Date?
    let isBombThrowActive: Bool
    let isKnifeThrowActive: Bool
    let isInventoryEnemyTargetSelectionActive: Bool
    let onNextWaveTap: (_ arrowOffsetX: CGFloat, _ arrowOffsetY: CGFloat) -> Void

    var body: some View {
        Group {
            if enemyCount > 0,
               enemyStates.count == enemyCount,
               enemyStates.allSatisfy({ $0.dead && !$0.dying }),
               !isRogueWalking {
                GeometryReader { geo in
                    let cx = geo.size.width / 2
                    let cy = geo.size.height / 2
                    let arrowOffsetX = GameConstants.spriteFrameSize * 0.75 - 21
                    let arrowOffsetY: CGFloat = 33
                    TimelineView(.periodic(from: nextWaveArrowAnimationStartDate, by: 0.12)) { context in
                        let stepInterval: Double = 0.12
                        let stepsFirstCycleCount: Int = 7
                        let stepsSubsequentCycleCount: Int = 8
                        let elapsedSteps: Int = max(0, Int(floor(context.date.timeIntervalSince(nextWaveArrowAnimationStartDate) / stepInterval)))

                        let animatedOffsetX: CGFloat = {
                            if elapsedSteps < stepsFirstCycleCount {
                                return -15 + (CGFloat(elapsedSteps) * 3)
                            }
                            let subsequentIndex = (elapsedSteps - stepsFirstCycleCount) % stepsSubsequentCycleCount
                            switch subsequentIndex {
                            case 0: return -18
                            case 1: return -15
                            case 2: return -12
                            case 3: return -9
                            case 4: return -6
                            case 5: return -3
                            case 6: return 0
                            default: return 3
                            }
                        }()

                        Button(action: { onNextWaveTap(arrowOffsetX, arrowOffsetY) }) {
                            Image("Arrow")
                                .interpolation(.none)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRogueAttacking || isRogueWalking || isEnemyAttackSequenceInProgress || isRogueDead || rogueDamageStartDate != nil || rogueDieStartDate != nil || isBombThrowActive || isKnifeThrowActive || isInventoryEnemyTargetSelectionActive)
                        .position(
                            x: cx + arrowOffsetX + animatedOffsetX,
                            y: cy + arrowOffsetY
                        )
                        .accessibilityLabel("Next wave")
                        .accessibilityHint("Spawn new enemies")
                    }
                }
                .onAppear {
                    nextWaveArrowAnimationStartDate = .now
                }
            }
        }
    }
}

private struct GameOverlaysRoomWipeLayer: View {
    let isRoomWiping: Bool
    let roomWipeProgress: CGFloat

    var body: some View {
        Group {
            if isRoomWiping {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .offset(x: roomWipeProgress * geo.size.width, y: 0)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                .zIndex(1000)
            }
        }
    }
}

// MARK: - GameOverlaysView (in same file so type is in scope for IDE)
struct GameOverlaysView: View {
    let damagedEnemyIndex: Int?
    let enemyDamageStartDate: Date?
    let rogueOffsetX: CGFloat
    let rogueOffsetY: CGFloat
    let heartsRemaining: Int
    let manaRemaining: Int
    let isRogueDead: Bool
    let rogueDamageStartDate: Date?
    let rogueDieStartDate: Date?
    let rogueDodgeStartDate: Date?
    let isEnemyAttackSequenceInProgress: Bool
    let activeEnemyAttackingIndex: Int?
    let activeEnemyAttackStartDate: Date?
    let isRogueAttacking: Bool
    let isAttackInputLocked: Bool
    let attackStartDate: Date?
    let isRogueWalking: Bool
    let walkStartDate: Date?
    let isRoomWiping: Bool
    let roomWipeProgress: CGFloat
    let roomNumber: Int
    let isTrollWave: Bool
    let isSlimeWave: Bool
    let isCyclopsWave: Bool
    let enemyCount: Int
    let enemyStates: [EnemyState]
    let enemyHitFloatStates: [Int: EnemyHitFloatState]
    let canTapEnemies: Bool
    let isShurikenActive: Bool
    let shurikenStartDate: Date?
    let potionDropEnemyIndex: Int?
    let potionDropImageName: String?
    let healEffectStartDate: Date?
    let manaRestoreEffectStartDate: Date?
    let isInventoryEnemyTargetSelectionActive: Bool
    let isBombThrowActive: Bool
    let bombThrowStartDate: Date?
    let bombTargetIndex: Int?
    let bombProjectileStartDate: Date?
    let bombGroundStartDate: Date?
    let isKnifeThrowActive: Bool
    let knifeThrowStartDate: Date?
    let knifeTargetIndex: Int?
    let knifeProjectileStartDate: Date?
    /// Touch target size: ~28% of sprite size, at least 44pt per HIG.
    let touchTargetSize: CGFloat
    let onEnemyTap: (Int) -> Void
    let onRogueTap: () -> Void
    let onRogueLongPress: () -> Void
    let onNextWaveTap: (_ arrowOffsetX: CGFloat, _ arrowOffsetY: CGFloat) -> Void

    @State private var nextWaveArrowAnimationStartDate: Date = .now

    private var enemyWaveProfile: EnemyWaveProfile {
        EnemyWaveProfile.resolve(isSlimeWave: isSlimeWave, isTrollWave: isTrollWave, isCyclopsWave: isCyclopsWave, roomNumber: roomNumber)
    }

    private func slotPosition(for index: Int) -> (x: CGFloat, y: CGFloat) {
        enemyWaveProfile.position(index: index, enemyCount: enemyCount)
    }

    var body: some View {
        ZStack {
            GameOverlaysRoomTorchesLayer(roomNumber: roomNumber)

            GameOverlaysEnemySpritesGrid(
                enemyWaveProfile: enemyWaveProfile,
                enemyCount: enemyCount,
                enemyStates: enemyStates,
                enemyHitFloatStates: enemyHitFloatStates,
                damagedEnemyIndex: damagedEnemyIndex,
                enemyDamageStartDate: enemyDamageStartDate,
                isShurikenActive: isShurikenActive,
                activeEnemyAttackingIndex: activeEnemyAttackingIndex,
                activeEnemyAttackStartDate: activeEnemyAttackStartDate,
                rogueOffsetX: rogueOffsetX,
                rogueOffsetY: rogueOffsetY,
                potionDropEnemyIndex: potionDropEnemyIndex,
                potionDropImageName: potionDropImageName
            )

            GameOverlaysRogueAndProjectileLayer(
                isRogueDead: isRogueDead,
                isRogueAttacking: isRogueAttacking,
                attackStartDate: attackStartDate,
                isRogueWalking: isRogueWalking,
                walkStartDate: walkStartDate,
                rogueDamageStartDate: rogueDamageStartDate,
                rogueDieStartDate: rogueDieStartDate,
                rogueDodgeStartDate: rogueDodgeStartDate,
                isBombThrowActive: isBombThrowActive,
                bombThrowStartDate: bombThrowStartDate,
                isKnifeThrowActive: isKnifeThrowActive,
                knifeThrowStartDate: knifeThrowStartDate,
                isShurikenActive: isShurikenActive,
                shurikenStartDate: shurikenStartDate,
                rogueOffsetX: rogueOffsetX,
                rogueOffsetY: rogueOffsetY,
                healEffectStartDate: healEffectStartDate,
                manaRestoreEffectStartDate: manaRestoreEffectStartDate,
                isBombThrowActiveForGround: isBombThrowActive,
                bombProjectileStartDate: bombProjectileStartDate,
                bombGroundStartDate: bombGroundStartDate,
                bombTargetIndex: bombTargetIndex,
                isKnifeThrowActiveForProj: isKnifeThrowActive,
                knifeProjectileStartDate: knifeProjectileStartDate,
                knifeTargetIndex: knifeTargetIndex,
                slotPosition: slotPosition(for:)
            )

            GameOverlaysTouchLayer(
                enemyWaveProfile: enemyWaveProfile,
                enemyCount: enemyCount,
                enemyStates: enemyStates,
                touchTargetSize: touchTargetSize,
                rogueOffsetX: rogueOffsetX,
                rogueOffsetY: rogueOffsetY,
                isAttackInputLocked: isAttackInputLocked,
                isRogueWalking: isRogueWalking,
                canTapEnemies: canTapEnemies,
                isInventoryEnemyTargetSelectionActive: isInventoryEnemyTargetSelectionActive,
                isBombThrowActive: isBombThrowActive,
                isKnifeThrowActive: isKnifeThrowActive,
                onEnemyTap: onEnemyTap,
                onRogueTap: onRogueTap,
                onRogueLongPress: onRogueLongPress
            )

            GameOverlaysNextWaveArrowLayer(
                nextWaveArrowAnimationStartDate: $nextWaveArrowAnimationStartDate,
                enemyCount: enemyCount,
                enemyStates: enemyStates,
                isRogueWalking: isRogueWalking,
                isRogueAttacking: isRogueAttacking,
                isEnemyAttackSequenceInProgress: isEnemyAttackSequenceInProgress,
                isRogueDead: isRogueDead,
                rogueDamageStartDate: rogueDamageStartDate,
                rogueDieStartDate: rogueDieStartDate,
                isBombThrowActive: isBombThrowActive,
                isKnifeThrowActive: isKnifeThrowActive,
                isInventoryEnemyTargetSelectionActive: isInventoryEnemyTargetSelectionActive,
                onNextWaveTap: onNextWaveTap
            )

            GameOverlaysRoomWipeLayer(isRoomWiping: isRoomWiping, roomWipeProgress: roomWipeProgress)

            GameOverlaysHeartsHUD(heartsRemaining: heartsRemaining)

            GameOverlaysManaHUD(manaRemaining: manaRemaining)
        }
    }
}

/// Sizes from the asset catalog — no extra scaling; one horizontal strip, `GameConstants.bombThrownFrameCount` frames wide.
private enum BombThrownAssetLayout {
    static var stripPointSize: CGSize {
        #if os(watchOS)
        if let img = UIImage(named: "BombThrown") {
            return img.size
        }
        #endif
        return CGSize(width: 32, height: 32)
    }

    static var frameWidth: CGFloat {
        stripPointSize.width / CGFloat(GameConstants.bombThrownFrameCount)
    }

    static var frameHeight: CGFloat {
        stripPointSize.height
    }
}

private struct BombThrownFlightView: View {
    let startDate: Date
    let duration: Double
    let fromX: CGFloat
    let fromY: CGFloat
    let toX: CGFloat
    let toY: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: min(1.0 / 30.0, GameConstants.bombThrownFrameDuration / 4))) { context in
            let rawT = context.date.timeIntervalSince(startDate) / duration
            let t = min(1, max(0, rawT))
            let x = fromX + (toX - fromX) * t
            let y = fromY + (toY - fromY) * t

            let elapsed = context.date.timeIntervalSince(startDate)
            let frameIndex = Int(elapsed / GameConstants.bombThrownFrameDuration) % GameConstants.bombThrownFrameCount
            let fw = BombThrownAssetLayout.frameWidth
            let fullW = BombThrownAssetLayout.stripPointSize.width
            let h = BombThrownAssetLayout.frameHeight

            Image("BombThrown")
                .interpolation(.none)
                .resizable()
                .frame(width: fullW, height: h)
                .offset(x: -CGFloat(frameIndex) * fw)
                .frame(width: fw, height: h, alignment: .leading)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(x: x, y: y)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}

/// `KnifeThrown` horizontal strip sizing — matches `BombThrown` pattern.
private enum KnifeThrownAssetLayout {
    static var stripPointSize: CGSize {
        #if os(watchOS)
        if let img = UIImage(named: "KnifeThrown") {
            return img.size
        }
        #endif
        return CGSize(width: 32, height: 32)
    }

    static var frameWidth: CGFloat {
        stripPointSize.width / CGFloat(GameConstants.knifeThrownFrameCount)
    }

    static var frameHeight: CGFloat {
        stripPointSize.height
    }
}

private struct KnifeThrownFlightView: View {
    let startDate: Date
    let duration: Double
    let fromX: CGFloat
    let fromY: CGFloat
    let toX: CGFloat
    let toY: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: min(1.0 / 30.0, GameConstants.knifeThrownFrameDuration / 4))) { context in
            let rawT = context.date.timeIntervalSince(startDate) / duration
            let t = min(1, max(0, rawT))
            let x = fromX + (toX - fromX) * t
            let y = fromY + (toY - fromY) * t

            let elapsed = context.date.timeIntervalSince(startDate)
            let frameIndex = Int(elapsed / GameConstants.knifeThrownFrameDuration) % GameConstants.knifeThrownFrameCount
            let fw = KnifeThrownAssetLayout.frameWidth
            let fullW = KnifeThrownAssetLayout.stripPointSize.width
            let h = KnifeThrownAssetLayout.frameHeight

            Image("KnifeThrown")
                .interpolation(.none)
                .resizable()
                .frame(width: fullW, height: h)
                .offset(x: -CGFloat(frameIndex) * fw)
                .frame(width: fw, height: h, alignment: .leading)
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .offset(x: x, y: y)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}

private struct TorchView: View {
    let offsetX: CGFloat
    let offsetY: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: GameConstants.spriteFrameDuration)) { context in
            SpriteSheetView(
                name: "Torch",
                frameCount: 8,
                date: context.date,
                frameDuration: GameConstants.spriteFrameDuration
            )
        }
        .frame(width: 48, height: 48)
        .offset(x: offsetX, y: offsetY)
        .allowsHitTesting(false)
    }
}

private struct EnemyDeathView: View {
    let name: String
    let frameCount: Int
    let deathStartDate: Date?
    let offsetX: CGFloat
    let offsetY: CGFloat
    let potionDropImageName: String?

    var body: some View {
        TimelineView(.animation(minimumInterval: EnemiesConstants.deathStripFrameDuration)) { context in
            ZStack {
                SpriteSheetView(
                    name: name,
                    frameCount: frameCount,
                    date: context.date,
                    animationStartDate: deathStartDate,
                    frameDuration: EnemiesConstants.deathStripFrameDuration,
                    loopAnimation: false
                )

                if let imageName = potionDropImageName, let start = deathStartDate {
                    let t = context.date.timeIntervalSince(start)
                    let startAt = 2.0 * EnemiesConstants.deathStripFrameDuration
                    let translateDuration = 3.0 * EnemiesConstants.deathStripFrameDuration
                    let holdDuration: Double = 1.0
                    let endAt = startAt + translateDuration + holdDuration

                    if t >= startAt && t <= endAt {
                        let translateProgress = min(max((t - startAt) / translateDuration, 0), 1)
                        let potionYOffset = -18.0 - 18.0 * translateProgress
                        Image(imageName)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .offset(x: 0, y: potionYOffset)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(width: GameConstants.spriteFrameSize, height: GameConstants.spriteFrameSize)
        .offset(x: offsetX, y: offsetY)
        .allowsHitTesting(false)
    }
}

private struct HealEffectView: View {
    let startDate: Date
    let offsetX: CGFloat
    let offsetY: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: GameConstants.healFrameDuration)) { context in
            SpriteSheetView(
                name: "Heal",
                frameCount: GameConstants.healFrameCount,
                date: context.date,
                animationStartDate: startDate,
                frameDuration: GameConstants.healFrameDuration,
                loopAnimation: false
            )
        }
        .frame(width: GameConstants.healSpriteFrameSize, height: GameConstants.healSpriteFrameSize)
        .offset(x: offsetX, y: offsetY - GameConstants.healEffectYOffset)
        .allowsHitTesting(false)
    }
}

private struct ManaRestoreEffectView: View {
    let startDate: Date
    let offsetX: CGFloat
    let offsetY: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: GameConstants.manaRestoreFrameDuration)) { context in
            SpriteSheetView(
                name: "ManaRestore",
                frameCount: GameConstants.manaRestoreFrameCount,
                date: context.date,
                animationStartDate: startDate,
                frameDuration: GameConstants.manaRestoreFrameDuration,
                loopAnimation: false
            )
        }
        .frame(width: GameConstants.healSpriteFrameSize, height: GameConstants.healSpriteFrameSize)
        .offset(x: offsetX, y: offsetY - GameConstants.manaRestoreEffectYOffset)
        .allowsHitTesting(false)
    }
}

private struct HitFloatTextView: View {
    let damageAmount: Int
    let showCritBang: Bool
    let startDate: Date

    private var label: String {
        "\(damageAmount)\(showCritBang ? "!" : "")"
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSince(startDate)
            if t < GameConstants.critTextDuration {
                let progress = min(max(t / GameConstants.critTextDuration, 0), 1)
                let y = GameConstants.critTextBaseYOffset - (GameConstants.critTextTranslateUpPx * CGFloat(progress))
                let opacity = 1.0 - progress

                Text(label)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    // Black drop shadow to keep the text readable over sprites.
                    .shadow(color: .black.opacity(0.95), radius: 1, x: 0, y: 1)
                    .offset(y: y)
                    .opacity(opacity)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
        .frame(width: GameConstants.spriteFrameSize, height: GameConstants.spriteFrameSize, alignment: .center)
    }
}

private struct EnemySpriteView: View {
    let isAttacking: Bool
    let enemyAttackStartDate: Date?
    let attackName: String
    let rogueOffsetX: CGFloat
    let rogueOffsetY: CGFloat
    /// Applied only during attack translation (positive moves enemy right).
    let attackOffsetXAdjustment: CGFloat
    let isDamaged: Bool
    let enemyDamageStartDate: Date?
    let offsetX: CGFloat
    let offsetY: CGFloat
    let idleStartFrame: Int?
    let idleName: String
    let damageName: String

    private static let damageKnockbackPx: CGFloat = 3
    private static let enemyDamageDuration: Double = Double(GameConstants.attackFrameCount) * GameConstants.attackFrameDuration

    var body: some View {
        let effectiveIsDamaged = isDamaged && !isAttacking
        // Enemy attack translation should be anchored to the rogue's *normal idle* position,
        // not the rogue's transient dodge/knockback offsets.
        let finalOffsetX: CGFloat = isAttacking
            ? (GameConstants.rogueIdleOffsetX + GameConstants.enemyToRogueSpacingPx + attackOffsetXAdjustment)
            : offsetX
        let finalOffsetY: CGFloat = isAttacking ? GameConstants.rogueIdleOffsetY : offsetY

        let attackOrDamageInterval: Double = isAttacking ? GameConstants.enemyAttackFrameDuration : GameConstants.attackFrameDuration
        TimelineView(.animation(minimumInterval: (isAttacking || effectiveIsDamaged) ? attackOrDamageInterval : GameConstants.spriteFrameDuration)) { context in
            let damageOffsetX: CGFloat = {
                guard effectiveIsDamaged, let start = enemyDamageStartDate else { return 0 }
                let t = context.date.timeIntervalSince(start)
                let half = Self.enemyDamageDuration / 2
                if t <= 0 || t >= Self.enemyDamageDuration { return 0 }
                if t < half {
                    return Self.damageKnockbackPx * CGFloat(t / half)
                }
                return Self.damageKnockbackPx * CGFloat((Self.enemyDamageDuration - t) / half)
            }()

            let spriteName: String = isAttacking
                ? attackName
                : (effectiveIsDamaged ? damageName : idleName)
            let frameCount: Int = isAttacking
                ? GameConstants.attackFrameCount
                : (effectiveIsDamaged ? GameConstants.attackFrameCount : GameConstants.spriteFrameCount)
            let animationStart: Date? = isAttacking ? enemyAttackStartDate : (effectiveIsDamaged ? enemyDamageStartDate : nil)
            let startFrame: Int? = (isAttacking || effectiveIsDamaged) ? nil : idleStartFrame
            let frameDuration: Double = isAttacking
                ? GameConstants.enemyAttackFrameDuration
                : (effectiveIsDamaged ? GameConstants.attackFrameDuration : GameConstants.spriteFrameDuration)
            let loopAnimation = !(isAttacking || effectiveIsDamaged)

            SpriteSheetView(
                name: spriteName,
                frameCount: frameCount,
                date: context.date,
                startFrame: startFrame,
                animationStartDate: animationStart,
                frameDuration: frameDuration,
                loopAnimation: loopAnimation
            )
            .offset(x: damageOffsetX, y: 0)
        }
        .frame(width: GameConstants.spriteFrameSize, height: GameConstants.spriteFrameSize)
        .offset(x: finalOffsetX, y: finalOffsetY)
        .allowsHitTesting(false)
    }
}

private struct RogueSpriteOverlay: View {
    let isAttacking: Bool
    let attackStartDate: Date?
    let isWalking: Bool
    let walkStartDate: Date?
    let rogueDamageStartDate: Date?
    let rogueDieStartDate: Date?
    let rogueDodgeStartDate: Date?
    let isBombThrowActive: Bool
    let bombThrowStartDate: Date?
    let isKnifeThrowActive: Bool
    let knifeThrowStartDate: Date?
    let isShurikenActive: Bool
    let shurikenStartDate: Date?
    let offsetX: CGFloat
    let offsetY: CGFloat

    var body: some View {
        let isDying = rogueDieStartDate != nil
        let isTakingDamage = rogueDamageStartDate != nil
        let isDodging = rogueDodgeStartDate != nil

        let minInterval: Double = {
            if isDying { return GameConstants.rogueDieFrameDuration }
            if isTakingDamage { return GameConstants.rogueDamageFrameDuration }
            if isDodging { return GameConstants.rogueDodgeFrameDuration }
            if isKnifeThrowActive { return GameConstants.knifeThrowFrameDuration }
            if isBombThrowActive { return GameConstants.bombThrowFrameDuration }
            if isShurikenActive { return GameConstants.shurikenFrameDuration }
            if isAttacking { return GameConstants.attackFrameDuration }
            if isWalking { return GameConstants.walkFrameDuration }
            return GameConstants.spriteFrameDuration
        }()

        TimelineView(.animation(minimumInterval: minInterval)) { context in
            if let dieStart = rogueDieStartDate {
                SpriteSheetView(
                    name: "RogueDie",
                    frameCount: GameConstants.rogueDieFrameCount,
                    date: context.date,
                    animationStartDate: dieStart,
                    frameDuration: GameConstants.rogueDieFrameDuration,
                    loopAnimation: false
                )
            } else if let damageStart = rogueDamageStartDate {
                SpriteSheetView(
                    name: "RogueDamage",
                    frameCount: GameConstants.rogueDamageFrameCount,
                    date: context.date,
                    animationStartDate: damageStart,
                    frameDuration: GameConstants.rogueDamageFrameDuration,
                    loopAnimation: false
                )
            } else if let dodgeStart = rogueDodgeStartDate {
                SpriteSheetView(
                    name: "RogueDodge",
                    frameCount: GameConstants.rogueDodgeFrameCount,
                    date: context.date,
                    animationStartDate: dodgeStart,
                    frameDuration: GameConstants.rogueDodgeFrameDuration,
                    loopAnimation: false
                )
            } else if isKnifeThrowActive, let kStart = knifeThrowStartDate {
                let elapsed = context.date.timeIntervalSince(kStart)
                if elapsed < GameConstants.knifeThrowDuration {
                    SpriteSheetView(
                        name: "RogueKnifeThrow",
                        frameCount: GameConstants.knifeThrowFrameCount,
                        date: context.date,
                        animationStartDate: kStart,
                        frameDuration: GameConstants.knifeThrowFrameDuration,
                        loopAnimation: false
                    )
                } else {
                    SpriteSheetView(
                        name: "RogueIdle",
                        frameCount: GameConstants.spriteFrameCount,
                        date: context.date,
                        animationStartDate: nil,
                        frameDuration: GameConstants.spriteFrameDuration,
                        loopAnimation: true
                    )
                }
            } else if isBombThrowActive, let bombStart = bombThrowStartDate {
                SpriteSheetView(
                    name: "RogueBombThrow",
                    frameCount: GameConstants.bombThrowFrameCount,
                    date: context.date,
                    animationStartDate: bombStart,
                    frameDuration: GameConstants.bombThrowFrameDuration,
                    loopAnimation: false
                )
            } else if isShurikenActive, let shurikenStart = shurikenStartDate {
                SpriteSheetView(
                    name: "RogueShuriken",
                    frameCount: GameConstants.shurikenFrameCount,
                    date: context.date,
                    animationStartDate: shurikenStart,
                    frameDuration: GameConstants.shurikenFrameDuration,
                    loopAnimation: false
                )
            } else if isAttacking {
                SpriteSheetView(
                    name: "RogueAttack",
                    frameCount: GameConstants.attackFrameCount,
                    date: context.date,
                    animationStartDate: attackStartDate,
                    frameDuration: GameConstants.attackFrameDuration,
                    loopAnimation: true
                )
            } else if isWalking {
                SpriteSheetView(
                    name: "RogueWalk",
                    frameCount: GameConstants.walkFrameCount,
                    date: context.date,
                    animationStartDate: walkStartDate,
                    frameDuration: GameConstants.walkFrameDuration,
                    loopAnimation: true
                )
            } else {
                SpriteSheetView(
                    name: "RogueIdle",
                    frameCount: GameConstants.spriteFrameCount,
                    date: context.date,
                    animationStartDate: nil,
                    frameDuration: GameConstants.spriteFrameDuration,
                    loopAnimation: true
                )
            }
        }
        .frame(width: GameConstants.spriteFrameSize, height: GameConstants.spriteFrameSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .offset(x: offsetX, y: offsetY)
        .allowsHitTesting(false)
    }
}

private struct SpriteSheetView: View {
    let name: String
    let frameCount: Int
    let date: Date
    var startFrame: Int? = nil
    var animationStartDate: Date? = nil
    var frameDuration: Double = GameConstants.spriteFrameDuration
    var loopAnimation: Bool = true

    @State private var startDate: Date? = nil
    @State private var cappedElapsed: Double? = nil

    private static let maxAdvancePerUpdate: Double = 1.5

    private func idealElapsed(for date: Date) -> Double? {
        if let animStart = animationStartDate {
            return date.timeIntervalSince(animStart)
        }
        if startFrame != nil, let sd = startDate {
            return date.timeIntervalSince(sd)
        }
        if animationStartDate == nil, startFrame == nil {
            return date.timeIntervalSinceReferenceDate
        }
        return nil
    }

    var body: some View {
        Group {
            if frameCount <= 0 {
                Color.clear
            } else {
                GeometryReader { geo in
                    let side = max(1, min(geo.size.width, geo.size.height))
                    let ideal = idealElapsed(for: date)
                    let elapsed: Double = {
                        guard let i = ideal else {
                            return date.timeIntervalSinceReferenceDate
                        }
                        return cappedElapsed ?? i
                    }()
                    let frameIndex: Int = {
                        if let _ = animationStartDate {
                            let index: Int = loopAnimation
                                ? Int(elapsed / frameDuration) % frameCount
                                : min(Int(elapsed / frameDuration), frameCount - 1)
                            return max(0, min(index, frameCount - 1))
                        }
                        if let sf = startFrame {
                            if startDate != nil {
                                return (Int(elapsed / GameConstants.spriteFrameDuration) + sf) % frameCount
                            }
                            return sf
                        }
                        return Int(elapsed / frameDuration) % frameCount
                    }()

                    Image(name)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: side * CGFloat(frameCount), height: side)
                        .frame(width: side, height: side, alignment: .leading)
                        .offset(x: -CGFloat(frameIndex) * side)
                        .animation(nil, value: name)
                        .clipped()
                        // watchOS: first-use `.drawingGroup()` compiles Metal pipelines and can freeze UI for seconds on cold launch.
#if !os(watchOS)
                        .drawingGroup()
#endif
                }
                .onAppear {
                    if startFrame != nil, startDate == nil {
                        startDate = Date()
                        cappedElapsed = nil
                    }
                }
                .onChange(of: date) { _, newDate in
                    guard let ideal = idealElapsed(for: newDate) else { return }
                    let maxAdvance = Self.maxAdvancePerUpdate * frameDuration
                    let prev = cappedElapsed ?? ideal
                    cappedElapsed = min(ideal, prev + maxAdvance)
                }
                .onChange(of: animationStartDate) { _, _ in
                    cappedElapsed = nil
                }
            }
        }
    }
}
