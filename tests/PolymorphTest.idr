||| Wander-of-polymorph tests.
|||
||| These live in their own module instead of M4Test.  The rc2 compiler's
||| memory use grows sharply with the size of a test module; moving these
||| checks keeps M4Test below the point where an incremental rebuild is
||| killed by the memory cap.
module PolymorphTest

import Data.List
import Data.Maybe
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

hasMessageContaining : String -> Outcome -> Bool
hasMessageContaining text out = any (\m => contains text m.text) out.messages

setPlayerStats : (Player -> Player) -> Game -> Game
setPlayerStats f g =
  let p : Player
      p = f g.player
  in { player := p } g

setMonster : Monster -> Game -> Game
setMonster m g =
  let lvl0 = currentLevel g
      lvl : Level
      lvl = { monsters := [m] } lvl0
  in updateCurrentLevel (const lvl) g

setItems : List Item -> Game -> Game
setItems xs g = { items := xs } g

addToPack : List Item -> Game -> Game
addToPack items g =
  let p : Player
      p = { inventory := map (.id) items ++ g.player.inventory } g.player
  in { items := g.items ++ items, player := p } g

wand : ItemId -> WandKind -> Int32 -> Item
wand iid k charges = MkItem iid (Wand k) InPack 1 0 False charges False

monsterById : MonsterId -> Game -> Maybe Monster
monsterById i g = find (\m => m.id == i) (currentLevel g).monsters

base : Game
base =
  let lvl0 = currentLevel sampleGame
      lvl : Level
      lvl = { monsters := [] } lvl0
  in updateCurrentLevel (const lvl) sampleGame

export
run : IO ()
run = do
  let rat = MkMonster 1 Emu (MkCoord 6 5) 100 100 Awake []

  let outPoly = step (Zap 414 E)
                  (setMonster rat
                    (addToPack [wand 414 WandPolymorph 5] base))
  check "polymorph announces a new monster"
    (hasMessageContaining "becomes a" outPoly)
  check "polymorph keeps one monster"
    (length (currentLevel outPoly.game).monsters == 1)

  -- An adjacent awake monster strikes instead of moving, so its position
  -- after the turn still reflects the polymorph itself.
  let adjacentRat = MkMonster 1 Emu (MkCoord 5 5) 100 100 Awake []
      outStay = step (Zap 414 E)
                  (setMonster adjacentRat
                    (addToPack [wand 414 WandPolymorph 5] base))
  check "polymorph keeps the target in place"
    (maybe False (\m => m.pos == MkCoord 5 5) (monsterById 1 outStay.game))

  let carried = MkItem 901 (Potion PotionHealing) (CarriedBy 1)
                        1 0 False 0 False
      gCarry = addToPack [wand 414 WandPolymorph 5]
                 (setItems [carried] (setMonster rat base))
      outCarry = step (Zap 414 E) gCarry
  check "polymorph keeps the target's carried items"
    (any (\i => i.id == 901 && i.location == CarriedBy 1)
         outCarry.game.items)

  -- Seed 15's first d26 gives Kestrel, a depth-one kind.
  let oldStatuses = [MkStatus Held 5, MkStatus Hasted 10]
      restless = MkMonster 1 Emu (MkCoord 6 5) 100 100 Chasing oldStatuses
      gKestrel = { rng := fromSeed 15 }
                   (setMonster restless
                     (addToPack [wand 420 WandPolymorph 5] base))
      outKestrel = step (Zap 420 E) gKestrel
      kestrel = monsterById 1 outKestrel.game
  check "polymorph chooses from the whole monster table"
    (maybe False (\m => m.kind == Kestrel) kestrel)
  check "polymorph rerolls hit points"
    (maybe False (\m => m.hp == m.maxHp && m.hp >= 1 && m.hp <= 8) kestrel)
  check "polymorph wakes the new monster and clears its statuses"
    (maybe False (\m => m.state == Awake && null m.statuses) kestrel)

  -- Seed 19's first d26 gives Xeroc, which is absent from depth one.
  let gXeroc = { rng := fromSeed 19 }
                 (setMonster restless
                   (addToPack [wand 421 WandPolymorph 5] base))
      outXeroc = step (Zap 421 E) gXeroc
  check "polymorph ignores the depth spawn band"
    (maybe False (\m => m.kind == Xeroc
                        && not (elem m.kind (spawnPool 1)))
                 (monsterById 1 outXeroc.game))
  let (xeroc, _) = polymorphMonster restless Xeroc (fromSeed 19)
  check "a polymorph into a xeroc starts a new disguise"
    (xeroc.kind == Xeroc && isMimicking xeroc)

  let flytrap = MkMonster 1 VenusFlytrap (MkCoord 6 5) 8 8 Chasing []
      heldPlayer = setPlayerStats
                     (\p => { statuses := [MkStatus Held 5] } p) base
      gFlytrap = { rng := fromSeed 15, vfHits := 3 }
                   (setMonster flytrap
                     (addToPack [wand 422 WandPolymorph 5] heldPlayer))
      outFlytrap = step (Zap 422 E) gFlytrap
  check "polymorph releases a player held by a flytrap"
    (not (hasStatus Held outFlytrap.game.player))
  check "polymorph leaves the flytrap damage counter alone"
    (outFlytrap.game.vfHits == 3)
