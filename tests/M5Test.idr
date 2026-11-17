||| M5 tests: the search command, the searching ring, and the first
||| fidelity fixes to potion healing and the wand of magic missile.
module M5Test

import Data.List
import Data.Maybe
import LambdaRogue.Core.Bitset
import LambdaRogue.Core.Dungeon
import LambdaRogue.Core.Game
import LambdaRogue.Core.Geometry
import LambdaRogue.Core.Item
import LambdaRogue.Core.Monster
import LambdaRogue.Core.Rng
import LambdaRogue.Core.Types
import System

check : String -> Bool -> IO ()
check name ok =
  if ok
     then putStrLn ("ok   " ++ name)
     else do
       putStrLn ("FAIL " ++ name)
       exitFailure

contains : String -> String -> Bool
contains needle hay = isInfixOf (unpack needle) (unpack hay)

hasMessage : String -> Outcome -> Bool
hasMessage text out = any (\m => m.text == text) out.messages

hasMessageContaining : String -> Outcome -> Bool
hasMessageContaining text out = any (\m => contains text m.text) out.messages

withoutMonsters : Game -> Game
withoutMonsters g =
  let lvl : Level
      lvl = { monsters := [] } (currentLevel g)
  in updateCurrentLevel (const lvl) g

setPlayerStats : (Player -> Player) -> Game -> Game
setPlayerStats f g =
  let p : Player
      p = f g.player
  in { player := p } g

setTraps : List Trap -> Game -> Game
setTraps ts g = updateCurrentLevel (\l => { traps := ts } l) g

setTileAt : Coord -> Tile -> Game -> Game
setTileAt c t g =
  updateCurrentLevel (\l => { tiles := setTile c t l.tiles } l) g

tileAtCoord : Coord -> Game -> Maybe Tile
tileAtCoord c g = tileAt (currentLevel g).tiles c

setMonster : Monster -> Game -> Game
setMonster m g =
  let lvl : Level
      lvl = { monsters := [m] } (currentLevel g)
  in updateCurrentLevel (const lvl) g

setItems : List Item -> Game -> Game
setItems xs g = { items := xs } g

setGold : Int32 -> Game -> Game
setGold n = setPlayerStats (\p => { gold := n } p)

monsterOf : Game -> Maybe Monster
monsterOf g = head' (currentLevel g).monsters

goldAt : Coord -> Game -> Maybe Item
goldAt c g =
  find (\i => i.kind == Gold && i.location == OnFloor g.depth c) g.items

itemLocationOf : ItemId -> Game -> Maybe ItemLocation
itemLocationOf iid g = map (.location) (find (\i => i.id == iid) g.items)

addToPack : List Item -> Game -> Game
addToPack items g =
  let p : Player
      p = { inventory := map (.id) items ++ g.player.inventory } g.player
  in { items := g.items ++ items, player := p } g

ringItem : ItemId -> RingKind -> Item
ringItem iid k = MkItem iid (Ring k) InPack 1 0 False 0 False

armorItem : ItemId -> ArmorKind -> Bool -> Item
armorItem iid k cursed = MkItem iid (Armor k) InPack 1 0 cursed 0 False

scrollItem : ItemId -> ScrollKind -> Item
scrollItem iid k = MkItem iid (Scroll k) InPack 1 0 False 0 False

equipLeft : Item -> Game -> Game
equipLeft it g =
  let p : Player
      p = { inventory := it.id :: g.player.inventory
          , leftRing := Just it.id } g.player
  in { items := it :: g.items, player := p } g

wand : ItemId -> WandKind -> Int32 -> Item
wand iid k charges = MkItem iid (Wand k) InPack 1 0 False charges False

potion : ItemId -> PotionKind -> Item
potion iid k = MkItem iid (Potion k) InPack 1 0 False 0 False

allDirs : List Dir
allDirs = [N, NE, E, SE, S, SW, W, NW]

adjacentTraps : List Trap
adjacentTraps =
  map (\c => MkTrap c ArrowTrap False)
      (map (\d => add (MkCoord 4 5) (delta d)) allDirs)

farTrap : Trap
farTrap = MkTrap (MkCoord 10 5) DartTrap False

trapAt : Coord -> Game -> Maybe Trap
trapAt c g = find (\t => t.pos == c) (currentLevel g).traps

revealedAt : Coord -> Game -> Bool
revealedAt c g = maybe False (\t => t.revealed) (trapAt c g)

base : Game
base = withoutMonsters sampleGame

searchTests : IO ()
searchTests = do
  let g = { rng := fromSeed 1 } (setTraps (adjacentTraps ++ [farTrap]) base)
      out = step Search g
  check "search consumes a turn" out.turnConsumed
  check "search does not move the player"
    (out.game.player.pos == g.player.pos)
  check "search reveals an adjacent trap"
    (any (\t => t.revealed) (currentLevel out.game).traps)
  check "search reports what it found"
    (hasMessageContaining "You found" out)
  check "search leaves distant traps hidden"
    (not (revealedAt (MkCoord 10 5) out.game))

  let quiet = step Search base
  check "searching an empty area says so"
    (hasMessage "You search but find nothing." quiet)
  check "searching an empty area still consumes a turn" quiet.turnConsumed

  let secretGame = { rng := fromSeed 1 }
                     (setTileAt (MkCoord 5 5) (Door Secret) base)
      hiddenMove = step (Move E) secretGame
  check "a hidden secret door blocks movement"
    (not hiddenMove.turnConsumed
     && hiddenMove.game.player.pos == secretGame.player.pos
     && hasMessage "There is a wall there." hiddenMove)
  check "bumping a secret door leaves it hidden"
    (tileAtCoord (MkCoord 5 5) hiddenMove.game == Just (Door Secret))

  let secretSearch = step Search secretGame
  check "search reveals an adjacent secret door as a closed door"
    (tileAtCoord (MkCoord 5 5) secretSearch.game == Just (Door Closed))
  check "search reports the secret door"
    (hasMessage "You found a secret door." secretSearch)
  check "searching for a secret door consumes a turn"
    secretSearch.turnConsumed

  let openedSecret = step (Move E) secretSearch.game
  check "a revealed secret door opens normally"
    (tileAtCoord (MkCoord 5 5) openedSecret.game == Just (Door Open)
     && hasMessage "You open the door." openedSecret)

  let farSecret = { rng := fromSeed 1 }
                    (setTileAt (MkCoord 10 5) (Door Secret) base)
      farSearch = step Search farSecret
  check "search leaves distant secret doors hidden"
    (tileAtCoord (MkCoord 10 5) farSearch.game == Just (Door Secret))

ringTests : IO ()
ringTests = do
  let ringGame = equipLeft (ringItem 500 RingSearching) base
      trapped = { rng := fromSeed 1 }
                  (setTraps [MkTrap (MkCoord 5 5) ArrowTrap False] ringGame)
      moved = step (Move N) trapped
  check "a searching ring reveals a trap after a move"
    (revealedAt (MkCoord 5 5) moved.game)
  check "a searching ring's search does not add a turn"
    (moved.game.turn == trapped.turn + 1)

  let waited = foldl (\g, _ => (step Wait g).game) trapped
                     (replicate 20 ())
  check "a searching ring does not search while waiting"
    (not (revealedAt (MkCoord 5 5) waited))

  let ringSecret = { rng := fromSeed 1 }
                     (equipLeft (ringItem 505 RingSearching)
                       (setTileAt (MkCoord 5 5) (Door Secret) base))
      movedSecret = step (Move N) ringSecret
  check "a searching ring reveals an adjacent secret door"
    (tileAtCoord (MkCoord 5 5) movedSecret.game == Just (Door Closed))

potionTests : IO ()
potionTests = do
  let heal = potion 501 PotionHealing
      low = setPlayerStats (\p => { hp := 1, maxHp := 12 } p)
              (addToPack [heal] base)
      outLow = step (Quaff 501) low
  check "healing rolls level d4"
    (outLow.game.player.hp >= 2 && outLow.game.player.hp <= 5)
  check "healing below max HP leaves max HP alone"
    (outLow.game.player.maxHp == 12)

  let heal2 = potion 502 PotionHealing
      overflow = setPlayerStats (\p => { hp := 11, maxHp := 12, level := 10 } p)
                   (addToPack [heal2] base)
      outOverflow = step (Quaff 502) overflow
  check "excess healing raises max HP by one"
    (outOverflow.game.player.maxHp == 13
     && outOverflow.game.player.hp == 13)

  let extra = potion 503 PotionExtraHealing
      extraOverflow = setPlayerStats
                        (\p => { hp := 11, maxHp := 12, level := 10 } p)
                        (addToPack [extra] base)
      outExtra = step (Quaff 503) extraOverflow
  check "extra healing raises max HP by one or two"
    (outExtra.game.player.maxHp >= 13
     && outExtra.game.player.maxHp <= 14
     && outExtra.game.player.hp == outExtra.game.player.maxHp)

wandTests : IO ()
wandTests = do
  let target = MkMonster 1 Emu (MkCoord 6 5) 100 100 Awake []
      g = setMonster target (addToPack [wand 504 WandMagicMissile 5] base)
      out = step (Zap 504 E) g
  check "magic missile deals 1d4 damage"
    (case find (\m => m.id == 1) (currentLevel out.game).monsters of
       Just m => m.hp >= 96 && m.hp <= 99
       Nothing => False)

  let dark : Game
      dark = updateCurrentLevel
               (\l => { explored := the Bitset empty } l) base
      lit = step (Zap 504 N) (addToPack [wand 504 WandLight 5] dark)
  check "a wand of light reveals the current room"
    (getBit 4 5 (currentLevel lit.game).explored
     && getBit 5 5 (currentLevel lit.game).explored)
  check "a wand of light leaves other rooms and corridors dark"
    (not (getBit 35 5 (currentLevel lit.game).explored)
     && not (getBit 25 5 (currentLevel lit.game).explored))
  check "a wand of light mentions the room"
    (hasMessageContaining "room" lit)

greedyTests : IO ()
greedyTests = do
  let gold = MkItem 600 Gold (OnFloor 1 (MkCoord 14 5)) 25 0 False 0 False
      orc = MkMonster 1 Orc (MkCoord 10 5) 6 6 Awake []
      g = setMonster orc (setItems [gold] base)
      afterMove = (step Wait g).game
  check "a greedy monster heads for visible gold"
    (maybe False (\m => m.pos == MkCoord 11 5) (monsterOf afterMove))

  let afterPickup = foldl (\gg, _ => (step Wait gg).game) g (replicate 5 ())
  check "a greedy monster carries picked-up gold"
    (itemLocationOf 600 afterPickup == Just (CarriedBy 1))
  check "picked-up gold leaves the floor"
    (isNothing (goldAt (MkCoord 14 5) afterPickup))

  let underfoot = MkItem 601 Gold (OnFloor 1 (MkCoord 10 5)) 25 0 False 0 False
      orcOnGold = MkMonster 2 Orc (MkCoord 10 5) 6 6 Awake []
      picked = (step Wait (setMonster orcOnGold (setItems [underfoot] base))).game
  check "a greedy monster picks up gold underfoot"
    (itemLocationOf 601 picked == Just (CarriedBy 2))

  let adjacentGold = MkItem 602 Gold (OnFloor 1 (MkCoord 5 5)) 25 0 False 0 False
      orcAdjacent = MkMonster 3 Orc (MkCoord 5 5) 6 6 Awake []
      attacked = (step Wait (setMonster orcAdjacent (setItems [adjacentGold] base))).game
  check "a greedy monster still attacks an adjacent player"
    (maybe False (\i => i.location == OnFloor 1 (MkCoord 5 5))
       (find (\i => i.id == 602) attacked.items))

  let zombieGold = MkItem 603 Gold (OnFloor 1 (MkCoord 10 5)) 25 0 False 0 False
      zombie = MkMonster 4 Zombie (MkCoord 10 5) 6 6 Awake []
      zombieMoved = (step Wait (setMonster zombie (setItems [zombieGold] base))).game
  check "a non-greedy monster ignores gold underfoot"
    (itemLocationOf 603 zombieMoved == Just (OnFloor 1 (MkCoord 10 5)))

  let carriedGold = MkItem 604 Gold (CarriedBy 1) 25 0 False 0 False
      carrying = MkMonster 1 Orc (MkCoord 10 5) 1 1 Asleep []
      strongPlayer = setPlayerStats
                       (\p => { pos := MkCoord 9 5, hp := 100, maxHp := 100
                              , level := 20, strength := 20 } p)
                       base
      gCarry = setMonster carrying (setItems [carriedGold] strongPlayer)
      afterAttack = foldl (\gg, _ => (step (Move E) gg).game) gCarry
                           (replicate 10 ())
  check "gold carried by a dead monster drops"
    (isNothing (monsterOf afterAttack)
     && any (\i => i.id == 604 && i.location == OnFloor 1 (MkCoord 10 5))
            afterAttack.items)

mimicTests : IO ()
mimicTests = do
  let mover = MkMonster 20 Xeroc (MkCoord 10 5) 50 50 Awake
                         [MkStatus Mimicking 1]
      afterMove = (step Wait (setMonster mover base)).game
  check "a moving xeroc stops mimicking"
    (maybe False (not . isMimicking) (monsterOf afterMove))

  let sleeper = MkMonster 21 Xeroc (MkCoord 60 5) 50 50 Asleep
                           [MkStatus Mimicking 1]
      afterSleep = (step Wait (setMonster sleeper base)).game
  check "a sleeping xeroc keeps its disguise"
    (maybe False isMimicking (monsterOf afterSleep))

  let attacker = MkMonster 22 Xeroc (MkCoord 5 5) 50 50 Awake
                            [MkStatus Mimicking 1]
      tough = setPlayerStats (\p => { hp := 100, maxHp := 100 } p) base
      afterAttack = (step Wait (setMonster attacker tough)).game
  check "an attacking xeroc stops mimicking"
    (maybe False (not . isMimicking) (monsterOf afterAttack))

  let toughMimic = MkMonster 23 Xeroc (MkCoord 5 5) 100 100 Asleep
                               [MkStatus Mimicking 1]
      strong = setPlayerStats (\p => { strength := 20, level := 20 } p) base
      afterHit = (step (Move E) (setMonster toughMimic strong)).game
  check "attacking a xeroc reveals it even on a miss"
    (maybe False (not . isMimicking) (monsterOf afterHit))

  let waker = MkMonster 24 Xeroc (MkCoord 8 5) 50 50 Asleep
                          [MkStatus Mimicking 1]
      woke = step Wait (setMonster waker base)
  check "waking a xeroc does not name it"
    (not (any (\msg => contains "xeroc" msg.text) woke.messages))
  check "a xeroc that only wakes keeps its disguise"
    (maybe False isMimicking (monsterOf woke.game))

  let coords = [MkCoord x y | x <- range 0 9, y <- range 0 9]
      spawns = map (\n => spawnMonsters 20 coords 1
                             (fromSeed (cast n)))
                   (the (List Nat) [1 .. 60])
      xerocs = concatMap (\(ms, _, _) =>
                            filter (\m => m.kind == Xeroc) ms) spawns
  check "spawned xerocs start disguised"
    (not (null xerocs) && all isMimicking xerocs)

withStatus : StatusKind -> Int32 -> Game -> Game
withStatus k turns =
  setPlayerStats (\p => { statuses := MkStatus k turns :: p.statuses } p)

curseTests : IO ()
curseTests = do
  let cursedArmor = armorItem 900 LeatherArmor True
      cursedRing = MkItem 901 (Ring RingProtection) InPack 1 0 True 0 False
      curseScroll = scrollItem 902 ScrollRemoveCurse
      g0 = setPlayerStats
             (\p => { worn := Just 900
                    , inventory := [900, 901, 902] ++ p.inventory } p)
             (setItems [cursedArmor, cursedRing, curseScroll] base)
      out = step (Read 902) g0
      itemCursed : ItemId -> Game -> Bool
      itemCursed iid g =
        maybe False (.cursed) (find (\i => i.id == iid) g.items)
  check "remove curse cleanses the worn armor"
    (not (itemCursed 900 out.game))
  check "remove curse leaves carried jewelry cursed"
    (itemCursed 901 out.game)
  check "remove curse consumes the scroll"
    (isNothing (find (\i => i.id == 902) out.game.items))

  let scrollOnly = scrollItem 903 ScrollRemoveCurse
      ringOnly = MkItem 904 (Ring RingProtection) InPack 1 0 True 0 False
      noArmor = setPlayerStats
                  (\p => { inventory := [903, 904] ++ p.inventory } p)
                  (setItems [scrollOnly, ringOnly] base)
      outNoArmor = step (Read 903) noArmor
  check "remove curse without worn armor leaves carried items cursed"
    (itemCursed 904 outNoArmor.game)

levitationTests : IO ()
levitationTests = do
  let trapped = { rng := fromSeed 1 }
                  (setTraps [MkTrap (MkCoord 5 5) ArrowTrap False] base)
      floating = withStatus Levitated 10 trapped
      out = step (Move E) floating
  check "levitation prevents trap damage"
    (out.game.player.hp == floating.player.hp)
  check "a trap under a levitating player stays hidden"
    (maybe False (not . revealed) (trapAt (MkCoord 5 5) out.game))
  check "levitation reports floating over the trap"
    (hasMessage "You float over a trap." out)

  let grounded = step (Move E) trapped
  check "the same trap fires without levitation"
    (grounded.game.player.hp < trapped.player.hp
     && revealedAt (MkCoord 5 5) grounded.game)

  let floorFood : Item
      floorFood = MkItem 700 (Food FoodRation)
                         (OnFloor 1 (MkCoord 4 5)) 1 0 False 0 False
      withFood = setItems [floorFood] base
      floatingFood = withStatus Levitated 10 withFood
      outPick = step PickUp floatingFood
  check "levitation prevents picking up items"
    (outPick.game.player.inventory == floatingFood.player.inventory
     && itemLocationOf 700 outPick.game == Just (OnFloor 1 (MkCoord 4 5)))
  check "a floating pickup says why"
    (hasMessage "You cannot reach the floor while floating." outPick)

  let onDown = setTileAt (MkCoord 4 5) (Stairs Down) base
      floatingDown = withStatus Levitated 10 onDown
      outFloatDown = step Descend floatingDown
  check "levitation prevents using stairs"
    (outFloatDown.game.depth == floatingDown.depth
     && hasMessage "You cannot use stairs while floating." outFloatDown)
  check "the same stairs work without levitation"
    ((step Descend onDown).game.depth == 2)

waitTimes : Nat -> Game -> Game
waitTimes Z g = g
waitTimes (S n) g = waitTimes n (step Wait g).game

regenTests : IO ()
regenTests = do
  let hurt = setPlayerStats (\p => { hp := 5, maxHp := 12 } p) base
      after17 = waitTimes 17 hurt
  check "natural healing waits for the level-1 interval"
    (after17.player.hp == 5 && after17.quietTurns == 17)
  let after18 = waitTimes 18 hurt
  check "natural healing restores a hit point after 18 quiet turns"
    (after18.player.hp == 6 && after18.quietTurns == 0)

  let poisoned = withStatus Poisoned 1
                   ({ quietTurns := 10 }
                      (setPlayerStats (\p => { hp := 5, maxHp := 12 } p) base))
      afterPoison = waitTimes 1 poisoned
  check "losing HP restarts the quiet-turn counter"
    (afterPoison.player.hp == 4 && afterPoison.quietTurns == 0)

  let healthyHigh = setPlayerStats (\p => { hp := 50, maxHp := 50, level := 9 } p) base
      afterFive = waitTimes 5 healthyHigh
  check "natural healing makes no roll at full health"
    (stateHex afterFive.rng == stateHex healthyHigh.rng
     && afterFive.player.hp == 50)

scoreTests : IO ()
scoreTests = do
  check "a death score is only the purse"
    (finalScore (setGold 123 base) == 123)
  let win : List Item -> Game
      win its = { over := Just Won } (setGold 10 (addToPack its base))
      dagger = MkItem 900 (Weapon Dagger) InPack 1 2 False 0 False
      cursedDagger = MkItem 901 (Weapon Dagger) InPack 1 (-2) True 0 False
      plate = MkItem 902 (Armor PlateMail) InPack 1 2 False 0 False
      arrows = MkItem 903 (Weapon Arrow) InPack 20 0 False 0 False
      food = MkItem 904 (Food FoodRation) InPack 2 0 False 0 False
      amulet = MkItem 905 Amulet InPack 1 0 False 0 False
      heal1 = potion 906 PotionHealing
      heal2 = potion 907 PotionHealing
      ring1 = MkItem 908 (Ring RingProtection) InPack 1 2 False 0 False
      ring2 = MkItem 909 (Ring RingProtection) InPack 1 2 False 0 False
      fire1 = wand 910 WandFire 5
      fire2 = wand 911 WandFire 5
  check "winning adds food and the Amulet to the purse"
    (finalScore (win [food, amulet]) == 10 + 4 + 1000)
  check "a weapon is valued from its enchantment"
    (finalScore (win [dagger]) == 10 + 3 * (3 * 4 + 1))
  check "a stack of arrows is valued by its count"
    (finalScore (win [arrows]) == 10 + 20)
  check "a cursed weapon is worth no less than zero"
    (finalScore (win [cursedDagger]) == 10)
  check "enchanted armor follows the sale formula"
    (finalScore (win [plate]) == 10 + 970)
  check "the first unknown potion is sold at half price"
    (finalScore (win [heal1, heal2]) == 10 + 65 + 130)
  check "a known potion is sold at full price"
    (finalScore ({ knownKinds := [Potion PotionHealing] } (win [heal1, heal2]))
       == 10 + 130 + 130)
  check "ring bonuses and identification affect the sale price"
    (finalScore (win [ring1, ring2]) == 10 + 300 + 600)
  check "wand charges add to the sale price once identified"
    (finalScore (win [fire1, fire2]) == 10 + 215 + 430)

public export
run : IO ()
run = do
  searchTests
  ringTests
  potionTests
  wandTests
  greedyTests
  mimicTests
  curseTests
  levitationTests
  regenTests
  scoreTests
  putStrLn "m5 tests passed"
