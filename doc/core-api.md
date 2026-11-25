# lambda-rogue Core API 設計

- Status: Draft 1.22（M5 スライス 17 の回復ポーションによる状態解除を反映）
- Date: 2026-11-15
- 対象: `LambdaRogue.Core.*` と `LambdaRogue.UI.*`、`LambdaRogue.Persist.*`
- 前提: `doc/design.md` Draft 1.28

## 1. 境界

- Core はゲームの真実だけを持つ。`IO`、`termui`、ファイル、端末、時計を import しない。
- Core の入力は `Command`、状態は `Game`、出力は `Outcome` の 3 つだけ。
- UI は `Game` を直接書き換えない。UI のモーダル、選択、スクロール、アニメーションは
  `App` の状態であり、Core の `Command` には含めない。
- 乱数は `LambdaRogue.Core.Rng.Rng` の純粋な値を使う。rc2base の
  `Xoroshiro128PlusPlus.Gen` は状態を取り出せないため、Core では状態型として使わない。
  `Rng` は同じ xoroshiro128++ を実装し、`Gen` との一致をテストで検証する。
- セーブ、スコア、JSON 永続化は `App` / `Persist` が担当する。Core は JSON を知らない。
  リプレイの意味的コマンド列と状態ダイジェストは純粋な `Core.Replay` が持つ。

```
Core.Types ── Core.Geometry ── Core.Rng ── Core.Bitset
     │              │              │           │
     ├──────────────┴──────────────┴───────────┤
     ▼                                         ▼
Core.Dungeon  Core.Fov  Core.Path  Core.Combat  Core.Monster
     │           │         │          │             │
     └───────────┴─────────┴──────────┴─────────────┘
                              │
                    Core.Item / Core.Effects
                              │
                         Core.Turn
                              │
                         Core.Game
                              │
                         Core.Message
```

`Core.Game` は他の Core モジュールを import してよいが、`App` / `UI` / `Persist` を
import してはならない。`UI` は `Core.Types` と `UI.ViewModel` だけを見る。

## 2. 基本型

```idris
public export
Depth : Type
Depth = Int32          -- 1 .. 26

public export
Turn : Type
Turn = Int32           -- 0 から始まる

public export
MonsterId, ItemId, RoomId, AppearanceId : Type
MonsterId = Bits32
ItemId = Bits32
RoomId = Bits32
AppearanceId = Bits32

public export
Bitset : Type
Bitset = Vect 28 Bits64     -- 80 * 22 = 1,760 bit

public export
record Coord where
  constructor MkCoord
  x, y : Int32

public export
data Dir = N | NE | E | SE | S | SW | W | NW

public export
delta : Dir -> Coord
```

- 座標はマップの左上を `(0, 0)` とする。
- マップは `80 x 22`。`x` は `0..79`、`y` は `0..21`。
- 範囲外は「壁でも床でもない」として扱い、`Command` の検証で弾く。
- 距離は `Int32` のチェビシェフ距離または二乗距離で計算する。`Nat` の
  `div`/`mod` は使わない。

## 3. 地形

```idris
public export
data DoorState = Open | Closed | Secret | Locked

public export
data StairDir = Up | Down

public export
data Tile
  = Rock
  | Floor
  | Corridor
  | Door DoorState
  | Stairs StairDir

public export
record Room where
  constructor MkRoom
  x, y, w, h : Int32
  dark : Bool

public export
data TrapKind
  = TrapDoor
  | ArrowTrap
  | Sleep
  | Bear
  | Teleport
  | DartTrap
  | Rust
  | Mysterious

public export
record Trap where
  constructor MkTrap
  pos : Coord
  kind : TrapKind
  revealed : Bool

public export
record Level where
  constructor MkLevel
  depth : Depth
  tiles : Vect 22 (Vect 80 Tile)  -- 行優先。`index y` が 80 列の行
  explored : Bitset           -- 80 * 22 bit
  rooms : List Room
  monsters : List Monster
  traps : List Trap
  upStairs, downStairs : Maybe Coord
```

- Idris 2 0.8 の base には不変 `Array` がないため、`tiles` は
  `Vect 22 (Vect 80 Tile)` とする。1,760 セルなので不変コピーで十分。
- `visible` は保存しない。各ターンの終わりに FOV から再計算する。
- `explored` は単調増加。見た地形は消さない。
- トラップは地形ではなく `Level.traps` に置く。未発見のトラップは
  `revealed = False` で、UI に出さない。
- ドアの `Secret` は探索するまで壁として見え、歩いても開かない。
  `Search` で見つけると閉じたドアになる。`Locked` は現状開けられず、
  「The door is locked.」を返してターンを消費しない。
- アイテムは `Level` ではなく `Game.items` に置く。`Item.location` が
  「床・所持・モンスター所持」を表す。
- `MonsterId` はラン全体で一意。`Level.monsters` は現在その階層にいる
  モンスターだけを持ち、訪問済み階層のモンスターは各 `Level` に残る。

## 4. アクター

```idris
public export
data Hand = LeftHand | RightHand

public export
record Player where
  constructor MkPlayer
  pos : Coord
  hp, maxHp : Int32
  strength, maxStrength : Int32
  armor : Int32
  level : Int32
  exp : Int32
  gold : Int32
  hunger : Int32
  inventory : List ItemId
  wielded, worn : Maybe ItemId
  leftRing, rightRing : Maybe ItemId
  weaponDice, weaponSides, weaponBonus : Int32
  ringArmor, ringDamage, ringAccuracy, ringStrength : Int32
  statuses : List Status

public export
data MonsterState
  = Asleep
  | Awake
  | Chasing
  | Fleeing

public export
record Monster where
  constructor MkMonster
  id : MonsterId
  kind : MonsterKind
  pos : Coord
  hp, maxHp : Int32
  state : MonsterState
  statuses : List Status
```

- `MonsterKind` は 26 種の有限列挙。名前・記号・レベル・AC・攻撃・基礎経験値・
  出現深度は `doc/rogue-reference.md` 4 章の表を正とする。HP は `レベル d8`。
- `MonsterId` はラン全体で単調増加。UI のアニメーションとログは ID で個体を追う。
- `Held` / `Confused` は `Status` だけに持たせ、`MonsterState` には入れない。
  `MonsterState` は AI の基本状態（睡眠・起床・追跡・逃走）だけを表す。
- `Player.armor` は装備中の防具の AC（10 が素手、低いほど良い）。強化値は
  `防具の AC - enchant` として `recomputeArmor` が反映する。
- `weaponDice` / `weaponSides` / `weaponBonus` は装備中の武器から展開した
  攻撃プロファイル。素手は `1d4`、武器なしの投擲は別経路。
- `ringArmor` / `ringDamage` / `ringAccuracy` / `ringStrength` は装備中の
  指輪の合計補正。`ringStrength` は `effectiveStrength` で基礎筋力に加算する。
- `hunger` は栄養値。初期値 1300、1 消費ターンごとに 1 減る。
- `Player.inventory` は所持順（新しい順）。UI の a-z は表示上のスロットであり、
  Core の ID とは独立させる。
- 装備中の ID は必ず `inventory` に含まれる。装備品を落とす・投げる前に
  外すことを `step` が強制する。
- モンスターがアイテムを持っているときは、`Item.location = CarriedBy id` で
  表す。`Monster` に所持リストを重複して持たせない。

## 5. アイテム

```idris
public export
data ItemKind
  = Weapon WeaponKind
  | Armor ArmorKind
  | Food FoodKind
  | Potion PotionKind
  | Scroll ScrollKind
  | Wand WandKind
  | Ring RingKind
  | Gold
  | Amulet

public export
data ItemLocation
  = OnFloor Depth Coord      -- 指定した階層の床
  | InPack                   -- プレイヤーの所持品
  | CarriedBy MonsterId      -- モンスターが所持

public export
record Item where
  constructor MkItem
  id : ItemId
  kind : ItemKind
  location : ItemLocation
  count : Int32
  enchant : Int32
  cursed : Bool
  charges : Int32
  protected : Bool
```

- `WeaponKind` / `ArmorKind` / `FoodKind` / `PotionKind` / `ScrollKind` /
  `WandKind` / `RingKind` は `doc/rogue-reference.md` 7〜12 章の表に対応する
  有限列挙。名前・記号・重み・価値・ダイスは `Core.Types` と `Core.Item` を正とする。
- `enchant` は武器・防具・指輪の強化値。武器は命中とダメージの両方に、
  防具は AC に、指輪は種類ごとの効果に使う。負値は呪い・逆効果を表す。
- `cursed` は外せない状態。`protected` は防具が錆びない状態。
- `charges` は杖の残り充填数。光の杖は生成時 10–19、それ以外は 3–7。
- 識別状態はアイテム個体ではなく `Game.knownKinds : List ItemKind` に持つ。
  同じ種別を 1 度識別すれば、以後の同種アイテムは実名で表示する。
- 未識別の外見は `Game.appearances : List (ItemKind, String)` に保存する。
  `itemDisplayNameIn : Game -> Item -> String` が実名・外見・強化値・呪い・
  充填数をまとめて表示名にする。`Gold` と `Amulet` は常に既知。
- `Gold` の `count` は金額。`Amulet` は 1 個だけ存在し、`count = 1`。
- 呪い・強化値・充填数は識別状態と独立に保持する。識別しても呪いが
  解けるとは限らない。

## 6. 状態異常

```idris
public export
data StatusKind
  = Confused
  | Blinded
  | Hasted
  | SeeInvisible
  | DetectMonsters
  | DetectFood
  | DetectMagic
  | Invisible
  | Poisoned
  | Held
  | Slowed
  | Paralyzed
  | Scared
  | Sleeping
  | Hallucinating
  | Levitated
  | ConfuseNext
  | Mimicking
  | Fainted
  | Cancelled

public export
record Status where
  constructor MkStatus
  statusKind : StatusKind
  remaining : Int32
```

- `remaining` はターン数。0 以下になったら `step` の終わりに取り除き、
  解除メッセージを出す。
- 状態は付与したターンの終わりにも 1 減る。`addStatus Held 4` は実効 3 行動、
  `addStatus Sleeping 6` は実効 5 行動のブロックになる。
- 同じ `StatusKind` を重複して持たない。`addStatus` は既存の残りターンと
  新しい残りターンの大きい方を採用する。
- `Mimicking` と `Cancelled` はモンスター専用で、`tickMonsterStatuses`
  では減らない。`Cancelled` は杖の cancellation で付き、そのモンスターの
  特殊攻撃・透明・擬態を無効にする。
- 毒は毎ターン 1 HP のダメージ。HP 0 で死亡する。
- `Sleeping` / `Paralyzed` / `Fainted` のプレイヤーはコマンドを受け付けず、
  ターンだけ消費する。`Fainted` は空腹度 0 以下で 1/5 の確率で付く。
  `Held` は移動を封じるが、隣接モンスターへの攻撃は許可する。
- UI はアイコン・名前・残りターンを表示する。色だけに依存しない。
- 効果の発生源と持続の詳細は `doc/rogue-reference.md` 15 章を参照する。

## 7. ゲーム状態

```idris
public export
data DeathCause
  = KilledBy MonsterKind
  | KilledByTrap TrapKind
  | Starved
  | Drained
  | OtherDeath String

public export
data GameOver = Dead DeathCause | Won

public export
record Game where
  constructor MkGame
  seed : Bits64
  rng : Rng
  turn : Turn
  depth : Depth
  player : Player
  levels : List Level        -- 現在の階層が先頭、以下は訪問順
  items : List Item          -- ラン全体のアイテム（床・所持・モンスター所持）
  nextMonsterId, nextItemId : Bits32
  knownKinds : List ItemKind
  appearances : List (ItemKind, String)
  messages : List Message    -- 直近 200 件程度
  over : Maybe GameOver
  visible : Bitset
```

- `levels` は現在の階層を先頭に持つ。同じ `depth` の `Level` を 2 つ持たない。
  `currentLevel` は先頭を返し、`updateCurrentLevel` は先頭だけを更新する。
- `items` はラン全体のアイテムを ID 昇順で持つ。現在の階層の床にあるものは
  `location = OnFloor depth pos` で引く。
- `knownKinds` は識別済みの種別、`appearances` はラン固有の未識別名。
  どちらもセーブ・リプレイ・状態ダイジェストに含める。
- `messages` は Core が生成したメッセージ履歴。UI の表示ログは
  `App` が別に持ち、フィルタ・折り返し・スクロールを担当する。
- `over = Just _` のとき、`step` は状態を変えず、メッセージも追加しない。
- `seed` は 64-bit。`rng` は 128-bit の `Rng`。どちらもセーブに含める。
- `nextMonsterId` / `nextItemId` はラン全体の ID 採番。既存の最大 ID より
  大きいことを不変条件とする。
- `visible` は各ターンの終わりに FOV から再計算する一時的なビットグリッド。
  `explored` は各 `Level` に残る。

## 8. メッセージとイベント

```idris
public export
data MessageKind = CombatMsg | ItemMsg | SystemMsg | WarningMsg | StoryMsg

||| 型付きの意味メッセージ。Core は表示言語を選ばない。
public export
data Msg
  = TakeDamage Int32
  | KillMonster AttackLead MonsterKind
  | ...

public export
record Message where
  constructor MkMessage
  turn : Turn
  kind : MessageKind
  key : String          -- 安定キー。旧セーブは ""
  args : List String    -- key と同じ順序の安定引数
  text : String         -- 正規の英語文。常にフォールバックに使う

public export
mkMessage : Turn -> MessageKind -> Msg -> Message

public export
legacyMessage : Turn -> MessageKind -> String -> Message
```

- `Core.Message` は `Msg` の全構築子に対して `msgEn`, `msgKey`, `msgArgs` を持つ。
  `mkMessage` はこの 3 つから `Message` を作る。
- `key` と `args` はセーブに保存する安定表現で、`text` は M5 以前と同じ英語文。
  `legacyMessage` は `key = ""` のメッセージを作り、常に `text` を表示する。
- 表示言語の選択は `App.Catalog` の `renderMessage` が行う。Core は
  `Language` もロケールも知らない。したがって言語切替は `gameDigest`、
  RNG、ターン、リプレイに影響しない。

```idris
public export
data Event
  = PlayerMoved Coord
  | MonsterMoved MonsterId Coord
  | PlayerAttacked MonsterId Int32
  | MonsterAttacked MonsterId Int32
  | MonsterWoke MonsterId
  | MonsterDied MonsterId
  | ItemPicked ItemId
  | ItemUsed ItemId
  | ItemDropped ItemId
  | DoorOpened Coord
  | TrapTriggered TrapKind Coord
  | LevelChanged Depth
  | PlayerLevelUp Int32
  | PlayerDied
  | PlayerWon
```

- `Event` は UI の演出用。ゲーム結果・乱数・メッセージ順序に影響しない。
- アニメーションの有無で `Outcome` の `game` / `messages` が変わってはならない。
- `Event` は ID と座標だけを持ち、文字列や色を持たない。UI が表示を決める。

## 9. コマンド

```idris
public export
data Command
  = Move Dir
  | Wait
  | Search
  | PickUp
  | Quaff ItemId
  | Read ItemId
  | Eat ItemId
  | Wield ItemId
  | Wear ItemId
  | PutOnRing ItemId
  | TakeOff ItemId
  | Drop ItemId
  | Throw ItemId Dir
  | Zap ItemId Dir
  | Descend
  | Ascend
```

- `Command` はゲーム状態を変える操作だけ。インベントリを開く、ヘルプを見る、
  カーソルを動かす、ログをスクロールする、は `App` の `Msg` であり、
  Core には渡さない。
- `Move` は移動先にモンスターがいれば攻撃、アイテムがあっても自動では拾わない。
- `Throw` / `Zap` は方向を明示する。UI の方向選択は `App` が解決してから
  `Command` を作る。
- 不正なコマンド（存在しない ID、装備していない物を外す、壁へ移動など）は
  `turnConsumed = False`、警告メッセージ、乱数消費なしで返す。

## 10. step の契約

```idris
public export
record Outcome where
  constructor MkOutcome
  game : Game
  messages : List Message
  events : List Event
  turnConsumed : Bool

public export
step : Command -> Game -> Outcome
```

### 10.1 前条件

- `game.over = Nothing`。`Just _` のときは状態を変えずに返す（no-op）。
- `Command` の ID は `game` 内に存在する。
- `Game` の不変条件（12 節）が成り立っている。

### 10.2 解決順

1. `game.over = Just _` なら no-op で返す。
2. プレイヤーが `Sleeping` / `Paralyzed` なら、警告メッセージを出して
   ターンだけ消費する。それ以外は `Command` を検証してプレイヤー行動を解決する。
3. ターンを消費しないコマンド（不正、キャンセル、インベントリ表示など）は
   ここで終了する。
4. `turn` を 1 進める。
5. 移動が成立し、searching の指輪を装着していれば、装着数と同じ回数の
   無料探索を行う。探索は隣接 8 マスの秘密のドアを方向順に、その後
   現在の階の未発見トラップを 1 体ずつ判定し、乱数を消費する。
   待機・攻撃・アイテム使用・階層移動では発動しない。
6. 階層移動がなく、加速によるスキップでなければ、モンスターを `MonsterId` の
   昇順で行動させる。各モンスターは状態異常を 1 減らし、再生なら HP を 1 回復し、
   行動する。`Fast` / `Hasted` は続けてもう 1 回行動する。
7. 死亡していなければ、状態異常の経過と毒ダメージ、自然回復、回復の指輪、
   空腹、slow digestion、テレポートの指輪を処理する。
8. 死亡判定を行い、`over` を確定する。
9. FOV と `explored` を更新し、`Outcome` を返す。

- `Search` は方向順に隣接 8 マスの秘密のドアを、その後 `Level.traps` の
  順に未発見トラップを `uniform (2 + 盲目 2 + 幻覚 3)` の 0 で発見する。
  1 ターン消費し、移動しない。秘密のドアは閉じたドアになる。
- 手順 4〜9 の順序はリプレイの同一性に直結する。変更する場合は
  `doc/rogue-reference.md` 16 章とテストを同時に更新する。
- モンスターの行動順はリストの添字ではなく `MonsterId` で固定する。
- 同じターンに複数のモンスターが死ぬ場合も、ID 昇順で処理する。
- FOV は最後に 1 回だけ計算する。UI の描画で FOV を再計算しない。
- 状態異常は付与したターンの終わりにも減るため、表示上の残りターンと
  実際にブロックできる行動数は 1 異なる。

### 10.3 ターンを消費しないもの

- インベントリ、ヘルプ、ログ、コマンドパレット、カーソル移動、方向選択。
- 不正なコマンド、キャンセル、確認ダイアログの開閉。
- セーブ、ロード、リプレイの一時停止。
- これらは Core に渡さないか、渡しても `turnConsumed = False` にする。

### 10.4 乱数の消費

- 乱数は Core の `step` の中だけで消費する。
- UI の描画、アニメーション、ログ、ツールチップ、ミニマップは乱数を消費しない。
- 乱数の消費順序は「プレイヤー行動 → searching の指輪の無料探索 →
  モンスター行動（ID 昇順）→ 状態異常 → 空腹/再生 → その他」の順で固定する。
- 乱数を使わない分岐（例: 壁への移動）では、乱数を引かない。
- `Outcome` に乱数状態を含める。`Game.rng` が唯一の正とする。

## 11. RNG ラッパー

`LambdaRogue/Core/Rng.idr` は xoroshiro128++ の状態とゲーム向け API を持つ。
rc2base の `Gen` は `export data` で状態を取り出せないため、状態は
`Rng` の値として持つ。アルゴリズムは rc2base と同じで、`fromSeed` / `next64`
が `mkGen` / `genNext` と一致することをテストで検証する。

```idris
public export
record Rng where
  constructor MkRng
  s0, s1 : Bits64

||| splitmix64 で 64-bit seed から初期化する。
public export
fromSeed : Bits64 -> Rng

public export
next64 : Rng -> (Bits64, Rng)

||| `next64` の下位 32 bit。
public export
next32 : Rng -> (Bits32, Rng)

||| 0 <= result < bound。bound = 0 のときは 0 を返し、乱数を消費しない。
public export
uniform : (bound : Bits64) -> Rng -> (Bits64, Rng)

||| n 個の sides 面ダイス。結果は n .. n * sides。
public export
roll : (n, sides : Int32) -> Rng -> (Int32, Rng)

||| percent / 100 の確率。0 は常に False、100 は常に True。
public export
chance : (percent : Int32) -> Rng -> (Bool, Rng)

public export
pick : List a -> Rng -> (Maybe a, Rng)

public export
shuffle : List a -> Rng -> (List a, Rng)

public export
stateHex : Rng -> String          -- 32 文字の小文字 hex

public export
stateFromHex : String -> Maybe Rng
```

- `uniform` は棄却サンプリングで偏りを避ける。`bound` が 2 の冪のときは
  棄却なしでマスクする。`bound = 0` または `1` は乱数を消費せず 0 を返す。
- `roll` は `uniform` を `n` 回呼ぶ。`n <= 0` または `sides <= 0` は 0 を返し、
  乱数を消費しない。
- `pick` は空リストで `Nothing` を返し、乱数を消費しない。
- `shuffle` は Fisher-Yates。末尾から `uniform (i+1)` で交換する。
  空リスト・1 要素では乱数を消費しない。
- `stateHex` は `s0` と `s1` を `toHex` で 16 文字ずつ並べる（合計 32 文字）。
- `stateFromHex` は長さ 32、`[0-9a-f]` のみを受け付ける。失敗は `Nothing`。
- ゲームの判定は整数で行い、`Double` の丸めに依存しない。`Double` が必要なのは
  UI の揺らぎやテストだけである。
- jump 系は提供しない。`genJump` は内部で `unsafePerformIO` を使うため、
  Core の通常経路では使わない。
- rc2base に `genState` / `genFromState` が入ったら、`Rng` の内部実装だけを
  `Gen` に差し替えられる。呼び出し側の API は変えない。

## 12. 不変条件

`step` の前後で次を満たす。テストとデバッグビルドで検証する。

1. `depth` は `1..26`。
2. `levels` の `depth` は重複しない。現在の `depth` の `Level` が存在する。
3. プレイヤーは現在の階層の歩行可能なタイル上にいる。モンスターと同じセルにいない。
4. `Game.items` の ID はラン全体で一意。全 `Level.monsters` の ID もラン全体で一意。
   `nextMonsterId` / `nextItemId` は既存の最大 ID より大きい。
5. `player.inventory` の ID は一意で、`Item.location = InPack` の全アイテムと
   正確に一致する（順序は所持順）。装備中の ID はすべて `inventory` に含まれる。
6. `inventory` の長さは 23 以下。a-z の表示スロット数（26）も超えない。
7. `explored` は単調増加。`visible` は `explored` の部分集合。
8. アミュレットは深度 26 に 1 つだけ存在する。取得後は `player` が持つ。
9. `over = Just _` のとき、それ以降の `step` は状態を変えない。
10. `turn` はターンを消費したときだけ増える。0 未満にならない。
11. `Item.location = OnFloor d _` の `d` は `levels` に存在する。
    `CarriedBy m` の `m` は全 `Level.monsters` のいずれかに存在する。
12. モンスターが死亡したとき、その `CarriedBy m` のアイテムは同じセルの
    `OnFloor` に移る。アイテムが消えることはない（使用・消費を除く）。

## 13. 状態ダイジェスト

リプレイ検証用に、`Game` の正規化表現から 16 文字の小文字 hex を作る。

```idris
public export
gameDigest : Game -> String
```

- 実装は `Core/Replay.idr` の FNV-1a 64-bit。初期案の `Core/Hash.idr` と
  `stateHash : Game -> Bits64` は現在持たない。
- 対象: `seed`, `rng`, `turn`, `depth`, `player`, `levels`, `items`,
  `nextMonsterId`, `nextItemId`, `knownKinds`, `appearances`, `over`,
  `visible`。正規化の詳細は `Core/Replay.idr` の `gameCode` を正とする。
- 対象外: `messages`（表示履歴であり、ログの切り詰めで変化するため）。
- リストは ID 昇順、`levels` は `depth` 昇順、マップは `y * 80 + x` 昇順で
  正規化する。
- ダイジェストは暗号学的ハッシュではない。改ざん検知ではなく、
  `replayMatches` による再現性確認に使う。衝突は許容する。
- 途中チェックポイントや `messagesHash` はまだない。

## 14. モジュール依存

```
Core.Types
  ├─ Core.Geometry
  ├─ Core.Rng
  ├─ Core.Bitset
  ├─ Core.Fov
  ├─ Core.Path
  ├─ Core.Combat
  ├─ Core.Survival
  ├─ Core.Item
  ├─ Core.Monster
  └─ Core.Dungeon
        └─ Core.Game
              ├─ Core.Replay
              └─ Core.Message
```

- `Core.Game` は `step` を公開し、プレイヤー行動・モンスター行動・生存処理を
  1 つの純粋な遷移にまとめる。
- `Core.Dungeon` は `Game` を知らない。`Depth`, ID の開始値, `Rng` から
  `Level` とその階層のアイテム列を返す。ID の確定は `Core.Game` が行う。
- `Core.Fov` は `Level` と `Coord` から `Bitset` を返す。`Game` を知らない。
- `Core.Combat` は `Player` と `Monster` の攻撃・経験値計算を担当する。
- `Core.Survival` は空腹・状態異常・飢餓のターン経過を担当する。
- `Core.Item` は生成・表示名・所持品ヘルパーを担当する。使用効果は `Core.Game`。
- `Core.Monster` は 5.4.4 のロスター、ステータス、生成、経験値ボーナスを持つ。
- `Core.Replay` は seed + 意味的コマンド列と `gameDigest` を持つ。

## 15. 未決事項

M4 の忠実性監査で確定した値と、意図的に残した差分は
`doc/rogue-reference.md` 17 章に集約した。Core API 上の残課題は次だけである。

- `Locked` ドアの開け方（鍵・壊す・魔法）。
- アミュレット取得後の上昇で、訪問済み階層のモンスターを再配置するか。
- スコア計算と死因別の表示。
- 巻物・杖の対象選択 UI と、Core 側の対象指定 API。
- 群れ生成。
- モンスターの遠距離攻撃（弓・投擲）とドラゴンの火炎反射。

## 16. M1 実装ノート（2026-10-28）

M1 は `src/LambdaRogue/Core/*` と `src/LambdaRogue/UI/*` の垂直スライスとして
実装した。上の章の最終形と意図的に異なる部分をここに記録する。

### 16.1 型の差分

- `Game` は次のフィールドだけを持つ。

  ```idris
  record Game where
    constructor MkGame
    seed : Bits64
    rng : Rng
    turn : Turn
    depth : Depth
    player : Player
    level : Level
    items : List Item
    nextItemId : Bits32
    messages : List Message
    over : Maybe GameOver
    visible : Bitset
  ```

  最終形の `levels : SortedMap Depth Level`、`nextMonsterId`、`knowledge`、
  `run` はまだない。M1 は 1 階層だけなので `level` を直接持つ。

- `Level` は `depth`, `tiles`, `explored`, `rooms`, `monsters` を持つ。
  `Grid = Vect 22 (Vect 80 Tile)` は Idris 2 0.8 の base に不変 `Array` が
  ないための選択で、マップの論理形は 22 行 × 80 列のまま。
- `visible` は `Level` ではなく `Game` に置き、ターン解決のたびに
  `Fov.compute` で作り直す。`explored` だけを `Level` に残す。M1 では
  永続化しないが、セーブ対象になるのは `explored` だけの予定。
- `Monster` は `id`, `kind`, `pos`, `hp`, `maxHp`, `state`。
  `MonsterKind = GiantRat` のみ。`Held` / `Confused` などの状態異常は
  `Status` に置く予定で、M1 の `MonsterState` には含めない。
- `ItemKind = Food FoodKind | Potion | Gold`、`FoodKind = FoodRation`。
  M1 が実際に配置するのは food ration だけ。`ItemLocation` は
  `OnFloor Depth Coord | InPack` で、`CarriedBy MonsterId` は M2 以降。
- `Command` は `Move Dir | Wait | PickUp | Descend | Ascend` のみ。
  走る、投げる、使う、装備する、階段を上る/下りる実処理は未実装。
- `MessageKind` のコンストラクタは `CombatMsg`, `ItemMsg`, `SystemMsg`,
  `WarningMsg`, `StoryMsg`。`Item` 型などとの名前衝突を避けるため。
- `Bitset = Vect 28 Bits64`。ビット番号は `y * 80 + x`。28 × 64 = 1,792
  ビットのうち、マップ外の 32 ビットは常に 0 として扱う。

### 16.2 `step` の M1 での解決順

```text
over = Just _        -> 状態を変えずに終了
コマンド検証         -> 不正なら Warning を追加（ターンも RNG も消費しない）
プレイヤー行動       -> 移動 / 待機 / 拾得 / 階段メッセージ / 攻撃
ターン消費時のみ:
  turn += 1
  MonsterId 昇順にモンスター行動
  visible と explored を再計算
```

- 壁への移動、空の床での拾得、階段でない場所での階段コマンドは
  ターンを消費しない。M1 の階段は正しい階段上でもメッセージだけで、
  ターンを消費しない。
- プレイヤーの攻撃はモンスターのセルへの移動として解決する。ダメージは
  1d4。モンスターの攻撃は隣接時のみで、ダメージは 1d3。
- モンスターは `Asleep` のとき、Chebyshev 距離 12 以内かつ
  `Fov.canSee` が真なら `Chasing` に遷移してメッセージを出す。
  `Awake` / `Chasing` は貪欲に 1 歩近づき、隣接していれば攻撃する。
  `Fleeing` は M1 では行動しない。
- モンスターは壁、閉じたドア、プレイヤー、他のモンスターのセルへは
  移動しない。プレイヤーが死亡したら、そのターンの残りのモンスターは
  行動しない。
- `Outcome.messages` はその `step` で新しく出たメッセージを時系列順で返す。
  `Game.messages` は新しい順で最大 200 件。

### 16.3 FOV

- プレイヤーが `dark = False` の部屋の中にいる場合、その部屋の矩形と
  外側 1 セルの壁をすべて visible にする。
- それ以外は半径 12 の円内の候補に対して Bresenham の線を引き、
  途中のセルが透明なら visible にする。対象セル自身は壁や閉じたドアでも
   visible にできる。
- 岩、閉じたドア、隠しドア、施錠ドアは視線を遮る。開いたドア、床、
  通路、階段は透明。
- `visible` はターンを消費したときだけ再計算する。壁にぶつかった等で
  ターンを消費しない場合は、FOV も変えない。

### 16.4 モジュール構成の差分

M1 では最終形の `Core/Path`, `Core/Combat`, `Core/Monster`, `Core/Item`,
`Core/Effects`, `Core/Turn`, `Core/Message`, `Core/Hash` をまだ分割して
いない。移動、戦闘、AI、拾得、階段、FOV 更新は `Core/Game.idr` に、
固定レベルは `Core/Dungeon.idr` にある。M2 でダンジョン生成と戦闘表を
入れるときに、最終形のモジュールへ分割する。

### 16.5 テスト

- `tests/CoreTest.idr`: 移動、壁、ドア、FOV、モンスターの起床・追跡・攻撃、
  拾得、階段、死亡、同じ seed とコマンド列の決定論（41 チェック）。
- `tests/MapViewTest.idr`: プレイヤー、アイテム、モンスターの重ね描き、
  未探索セルの非表示、探索済みセルの暗色表示（9 チェック）。
- `tests/ViewTest.idr`: 80x24 と 120x40 の行数、メッセージ、マップ、
  ステータス、サイドバー、ログ、サイズ警告（10 チェック）。
- `tests/PerfTest.idr`: 初期 FOV と全 1,760 セルの描画、`Wait` の
  ターン解決、step+render の計測。
- `tests/latency_probe.py`: PTY 上のキー入力からフレーム完了までの計測。
- `verify.sh`: ビルド、上記 Idris テスト、PTY スモークテストを実行する。

計測値と環境は `doc/m1-measurements.md` に記録した。

## 17. M2 実装ノート（2026-10-29）

M2 では上の最終形のうち、複数階層・生成・モンスター表・戦闘・成長・死亡を
実装した。空腹・装備・識別・状態異常・アミュレット・セーブ・リプレイは
まだ入っていない。以下の型が現在の実装である。

### 17.1 型の差分

```idris
record Player where
  constructor MkPlayer
  pos : Coord
  hp, maxHp : Int32
  strength : Int32
  armor : Int32
  level : Int32
  exp : Int32
  gold : Int32
  inventory : List ItemId

record Level where
  constructor MkLevel
  depth : Depth
  tiles : Grid
  explored : Bitset
  rooms : List Room
  monsters : List Monster
  traps : List Trap
  upStairs, downStairs : Maybe Coord

record Game where
  constructor MkGame
  seed : Bits64
  rng : Rng
  turn : Turn
  depth : Depth
  player : Player
  levels : List Level        -- 現在の階層が先頭。以下は訪問順
  items : List Item
  nextMonsterId, nextItemId : Bits32
  messages : List Message
  over : Maybe GameOver
  visible : Bitset
```

- `Room` は `x, y, w, h, dark` のみ。`id` と `maze` はまだない。
- `MonsterKind` は 8 種: `GiantRat | Kobold | Jackal | Bat | Snake | Zombie |
  Orc | Hobgoblin`。`Monster` は `id, kind, pos, hp, maxHp, state`。
- `ItemKind` は `Food FoodRation | Potion | Gold`。`Item` は
  `id, kind, location, count`。`CarriedBy` はまだない。
- `Command` は `Move Dir | Wait | PickUp | Descend | Ascend` のみ。
- `Event` は `PlayerMoved | MonsterMoved | PlayerAttacked | MonsterAttacked |
  MonsterWoke | MonsterDied | ItemPicked | DoorOpened | TrapTriggered |
  LevelChanged | PlayerLevelUp | PlayerDied`。
- `GameOver = Dead DeathCause | Won` だが、M2 で `Won` になる経路はない。
- `currentLevel : Game -> Level` は `levels` の先頭を返す。
  `updateCurrentLevel : (Level -> Level) -> Game -> Game` は先頭だけを更新する。
  `levels` が空の場合のフォールバックは `emptyLevel`。

### 17.2 生成

`Core.Dungeon.generateLevel` は次の順で 1 階層を作る。

1. 3x3 のスロット（26x7）に 9 部屋を生成する。部屋は 4〜10 x 3〜5。
2. 部屋を L 字通路で結び、部屋の境界に閉じたドアを置く。
3. 最初の部屋に上り階段、最後の部屋に下り階段を置く。深度 26 は下りなし。
4. 部屋のセルからモンスター、アイテム、トラップの候補を作り、
   使用済みセルを除外しながら配置する。
5. `GeneratedLevel` として `Level`, 階層のアイテム列, 次の RNG 状態,
   次のモンスター/アイテム ID を返す。

- `newGame seed` は深度 1 を生成し、プレイヤーを上り階段に置く。
  `sampleGame` は M1 の固定フィクスチャで、UI テスト用に残している。
- 下降は `Game.levels` の先頭に新しい `Level` を追加する。古い階層は残る。
  到着直後はモンスターターンを省略する。
- トラップは `Level.traps` に置き、`revealed` で表示を制御する。
  M2 の効果はトラップドア・矢・ダーツ・熊挟み・テレポート。
  睡眠・錆・不思議はメッセージのみ。
- テレポート先は現在地とモンスターのいるセルを除外した歩行可能セルから選ぶ。

### 17.3 モンスターと戦闘

- 出現数は `2 + depth/2`（上限 12）。深度ごとの重み付きプールから選び、
  80% を `Asleep`、残りを `Awake` で置く。ID はラン全体で単調増加。
- 睡眠中は Chebyshev 距離 12 以内かつ `Fov.canSee` が真なら `Chasing` に遷移。
  `Awake` / `Chasing` は貪欲に 1 歩近づき、隣接時に攻撃する。
  閉じたドアはモンスターも開けて通過できる。逃走・群れ・特殊能力は未実装。
- プレイヤー攻撃: `d20 + level + strengthBonus` 対 `10 + monsterAC`。
  ダメージは `1d4 + strengthBonus`。最低 1。
- モンスター攻撃: `d20 + monsterLevel` 対 `10 + armor + playerLevel`。
  ダメージは種族ごとのダイス。
- `strengthBonus s = max 0 ((s - 10) / 3)`。
- 経験値閾値は `max 10 (10 * level)`。閾値を超えるたびに
  level +1、strength +1、最大/現在 HP +1d6。複数レベル分を一度に処理できる。
- 戦闘・出現値は暫定であり、Rogue 5.4.4 の観測値ではない。

### 17.4 step の M2 での解決順

```text
over = Just _        -> 状態を変えずに終了
プレイヤー行動       -> 移動 / 待機 / 拾得 / 下降 / 上昇メッセージ / 攻撃 / 扉 / 罠
ターン消費時のみ:
  turn += 1
  階層が変わっていなければ MonsterId 昇順にモンスター行動
  visible と explored を再計算
```

- 壁、施錠ドア、空の床での拾得、階段でない場所での階段コマンド、
  深度 26 での下降はターンを消費しない。
- 閉じたドアへの移動はドアを開くが、プレイヤーはその場に残る。
- モンスターのいるセルへの移動は攻撃。モンスターを倒すと経験値を得る。
- トラップは移動後に発動し、`revealed := True` にしてから効果を適用する。
- プレイヤーが死んだら `over = Just (Dead cause)`、HP 0。
  以降の `step` は no-op。
- `Outcome.messages` はその `step` の新規メッセージを時系列順、
  `Game.messages` は新しい順で最大 200 件。

### 17.5 テストと検証

- `tests/CoreTest.idr`: 固定フィクスチャでの移動、FOV、扉（開く・施錠・
  モンスターの扉開け）、起床・追跡・攻撃、拾得、所持上限、gold、
  下降、上昇メッセージ、深度 26、矢・トラップドア・テレポート、
  死亡、決定論。
- `tests/DungeonTest.idr`: 深度 1..26 の生成不変条件、部屋の非重複、
  階段の存在と到達性、モンスター/アイテム/トラップの妥当性、
  ID の連続性、同じ seed の決定論、`newGame` の開始位置。
- `tests/CombatTest.idr`: 強さボーナス、AC、命中・外れ・殺害、
  RNG 消費、経験値と複数レベルアップ。
- `tests/MapViewTest.idr`, `tests/ViewTest.idr`: M2 の `currentLevel` と
  新しいステータス表示に追従。
- `tests/PerfTest.idr`: M1 固定マップに加え、生成レベル、生存可能な
  生成レベルでの step、生成 100 回の計測を追加。
- `verify.sh` は `build/ttc` を消してからビルドする。この rc2 ビルドでは
  依存モジュールの変更をインクリメンタルビルドが取りこぼすことがあるため。

### 17.6 M2 の既知の制約

- 上昇・帰還・アミュレット・勝利は M3。
- 食料・ポーションの使用、装備、識別、空腹、状態異常は M3/M4。
- セーブ、自動保存、リプレイ、状態ハッシュは未実装。
- モンスターの逃走、群れ、遠距離攻撃、特殊能力は未実装。
- 部屋数は常に 9。迷路・部屋数の減少・隠しドア・鍵付きドアは未実装。
- 戦闘式、モンスター表、出現重み、経験値曲線、gold 量、トラップ確率は
  暫定値であり、M4 の忠実性監査で原本の観測値に置き換える。

## 18. M3 実装ノート（2026-10-29）

M3 ではアイテム使用、装備、識別、空腹、状態異常、アミュレット、上昇、
勝利を追加した。上の最終形と意図的に異なる現在の型と契約をここに記録する。

### 18.1 型の差分

```idris
public export
record Item where
  constructor MkItem
  id : ItemId
  kind : ItemKind
  location : ItemLocation
  count : Int32
  enchant : Int32
  cursed : Bool

public export
record Player where
  constructor MkPlayer
  pos : Coord
  hp, maxHp : Int32
  strength, maxStrength : Int32
  armor : Int32
  level : Int32
  exp : Int32
  gold : Int32
  hunger : Int32
  inventory : List ItemId
  wielded, worn : Maybe ItemId
  weaponDice, weaponSides, weaponBonus : Int32
  statuses : List Status

public export
record Status where
  constructor MkStatus
  statusKind : StatusKind
  remaining : Int32

public export
record Game where
  constructor MkGame
  seed : Bits64
  rng : Rng
  turn : Turn
  depth : Depth
  player : Player
  levels : List Level        -- 現在の階層が先頭。以下は訪問順
  items : List Item
  nextMonsterId, nextItemId : Bits32
  knownKinds : List ItemKind -- ラン内で正体が判明した種別
  messages : List Message
  over : Maybe GameOver
  visible : Bitset
```

- `ItemKind` は `Weapon WeaponKind | Armor ArmorKind | Food FoodRation |
  Potion PotionKind | Gold | Amulet`。巻物・杖・指輪はまだない。
- `WeaponKind = Dagger | Mace | Sword | TwoHandedSword`、
  `ArmorKind = Leather | RingMail | ChainMail | PlateMail`。
- `PotionKind` は 12 種。`StatusKind` の `Confused` / `Blinded` /
  `HasteSelf` などとの名前衝突を避けるため、`PotionHealing`,
  `PotionConfusion`, `PotionBlindness`, `PotionTeleport` のように接頭辞を付ける。
- `StatusKind = Confused | Blinded | Hasted | SeeInvisible |
  DetectMonsters | Poisoned`。麻痺・ホールド・減速・再生・ドレイン・浮遊はまだない。
- `Player.armor` は装備中の防具による合計 AC ボーナス。
  `weaponDice` / `weaponSides` / `weaponBonus` は装備中の武器から導出した
  攻撃プロファイルで、素手は `1d4 + 0`。
- `knownKinds` はラン全体の識別状態。ポーションは使用、武器・防具は装備で
  種別が加わる。`Gold` と `Amulet` は常に既知として扱う。
- `Monster` は引き続き `id, kind, pos, hp, maxHp, state` のみ。
  モンスターの状態異常と変身は M4。
- `Event` は M2 のものに `ItemUsed ItemId`, `ItemDropped ItemId`,
  `PlayerWon` を加えた。`PlayerDied` は死因を持たない。

### 18.2 アイテム API

`Core.Item` が出現表、強化値・呪い、表示名、所持品検索を持つ。

```idris
public export
makeItem : Depth -> ItemId -> ItemKind -> Coord -> Rng -> (Item, Rng)

public export
spawnItems : Depth -> List Coord -> ItemId -> Rng
          -> (List Item, ItemId, Rng)

public export
spawnItemsWithFood : Depth -> List Coord -> ItemId -> Int32 -> Rng
                  -> (List Item, ItemId, Int32, Rng)

public export
itemKnown : List ItemKind -> Item -> Bool

public export
itemDisplayName : List ItemKind -> Item -> String

public export
itemDetail : List ItemKind -> Item -> String

public export
packItems : Game -> List Item

public export
findPackItem : Game -> ItemId -> Maybe Item
```

- `makeItem` は武器・防具のときだけ強化値と呪いを引き、金のときだけ数量を引く。
- `itemDisplayName` は未識別ポーションに外見名を返し、未識別の武器・防具には
  強化値と呪いを付けない。`itemKnown` は金とアミュレットを常に `True` にする。
- `packItems` は `Player.inventory` の ID 順にアイテムを返す。
  `findPackItem` は `location = InPack` も確認する。

### 18.3 空腹と状態異常 API

`Core.Survival` がターン経過の規則をまとめる。

```idris
public export
hungerMax, hungryAt, weakAt, starvingAt, starvingDeathAt : Int32

public export
data HungerState = Satiated | Normal | Hungry | Weak | Fainting

public export
hungerState : Int32 -> HungerState

public export
record SurvivalResult where
  constructor MkSurvivalResult
  player : Player
  messages : List Msg
  died : Maybe DeathCause

public export
tickSurvival : Player -> SurvivalResult
```

- 開始値は 1300。毎ターン -1。300 以下で hungry、150 以下で weak、
  0 以下で fainting。飢餓は HP を減らさず、`-850` で死亡する。
- `Fainted 2` は実効 1 行動を失う。失神判定は `survivalTurn` が
  `chance 20` で行い、失神中は重ねて判定しない。
- `tickSurvival` は状態異常の残りターンを 1 減らし、毒の毎ターンダメージ、
  失神の失効メッセージ、飢餓死の判定をまとめて返す。
- 盲目の FOV は `Core.Fov.computeBlinded`（半径 1、部屋の明かりなし）を使う。
- 加速中は偶数ターンのモンスター行動を省略する。混乱中の移動は
  `Rng.pick` で 8 方向から選び直す。

### 18.4 step の M3 での解決順

```text
over = Just _        -> 状態を変えずに終了
プレイヤー行動       -> 移動 / 待機 / 拾得 / 使用 / 装備 / 落下 / 階段 / 攻撃
ターン消費時のみ:
  turn += 1
  階層が変わっていない、かつ加速の偶数ターンでなければ
    MonsterId 昇順にモンスター行動
  死亡していなければ状態異常・毒・空腹を進める
  visible と explored を再計算
```

- アイテム使用・装備・拾得・落下は 1 ターン。インベントリを開く、選択する、
  閉じるは `App` の状態だけで、Core の `step` を呼ばない。
- 不正な使用（持っていない ID、飲めない物、呪われた装備の交換など）は
  ターンを消費せず、警告メッセージだけを返す。
- 深度 1 の上り階段でアミュレットを持つと `Won`。アミュレットなしでは
  警告してターンを消費しない。深度 2 以上からの上昇は訪問済み階層を再利用する。
- 上昇時は現在の階層を `levels` の末尾へ回し、上昇先を先頭にする。
  下降時は同じ深度の訪問済み階層があれば再生成せず再利用する。
- 勝利・死亡が確定したターンは、それ以降のモンスター行動と生存時間を進めない。

### 18.5 テストと検証

- `tests/M3Test.idr`: ポーション 12 種の効果と識別、食料と空腹閾値、
  飢餓・毒のダメージと失効、武器・防具の装備と呪い、落下、
  アミュレット生成と取得、上昇・勝利、階層の保持と再利用、
  盲目 FOV、混乱の乱数消費、加速のモンスターターン省略。
- `tests/MapViewTest.idr`: アミュレットの `"` 表示、モンスター感知による
  記憶済みモンスターの表示。
- `tests/ViewTest.idr`: インベントリ画面のタイトル、一覧、23 スロットの
  2 列表示、ステータス行。
- `tests/SubsTest.idr`: インベントリの選択、動作キー、Enter、Esc/i。
- `tests/PerfTest.idr`: 10,000 ターンの step 計測用に、飢餓で死亡しない
  だけの栄養を与えたフィクスチャを追加。
- `verify.sh` は M3 時点では `m3-test` と `subs-test` を実行していた
  （現在は §19.7 の単一テストランナー）。

### 18.6 M3 の既知の制約

- 巻物、杖、指輪、投げる、充填数、識別の巻物は未実装。
- ポーションの外見は種別ごとに固定で、ランごとのランダム化は未実装。
- 装備は武器 1・防具 1 のみ。指輪 2 枠と両手持ちの制約は未実装。
- 状態異常は 6 種のみ。麻痺、ホールド、減速、再生、ドレイン、浮遊は未実装。
- 空腹・ポーション効果・強化値・呪い率・武器/防具の値は暫定値であり、
  Rogue 5.4.4 の忠実性監査は M4 で行う。
- セーブ、自動保存、戦績、状態ハッシュ、リプレイは未実装。

## 19. M4 実装ノート（2026-10-30、スライス 1）

M4 はスライスに分割する。ここではスライス 1（巻物・杖・指輪・投げる・
ランごとの外見）の現在の型と契約を記録する。§18 と同様、上の最終形と
意図的に異なる部分を含む。§19.1 の `Item` / `Player` / `Game` は §18.1 の
同じ型を置き換える。

### 19.1 型の差分

```idris
public export
record Item where
  constructor MkItem
  id : ItemId
  kind : ItemKind
  location : ItemLocation
  count : Int32
  enchant : Int32
  cursed : Bool
  charges : Int32      -- 杖の残り充填。それ以外は 0
  protected : Bool     -- 防具の錆び防止

public export
record Monster where
  constructor MkMonster
  id : MonsterId
  kind : MonsterKind
  pos : Coord
  hp, maxHp : Int32
  state : MonsterState
  statuses : List Status

public export
record Player where
  constructor MkPlayer
  pos : Coord
  hp, maxHp : Int32
  strength, maxStrength : Int32
  armor : Int32
  level : Int32
  exp : Int32
  gold : Int32
  hunger : Int32
  inventory : List ItemId
  wielded, worn : Maybe ItemId
  leftRing, rightRing : Maybe ItemId
  weaponDice, weaponSides, weaponBonus : Int32
  ringArmor, ringDamage, ringAccuracy, ringStrength : Int32
  statuses : List Status

public export
record Game where
  constructor MkGame
  seed : Bits64
  rng : Rng
  turn : Turn
  depth : Depth
  player : Player
  levels : List Level
  items : List Item
  nextMonsterId, nextItemId : Bits32
  knownKinds : List ItemKind
  appearances : List (ItemKind, String)
  messages : List Message
  over : Maybe GameOver
  visible : Bitset
```

`StatusKind` には M3 の 6 種に加えて `DetectFood`, `Invisible`, `Held`,
`Slowed`, `Paralyzed`, `Scared`, `Sleeping` を追加した。`Status` は
`MkStatus statusKind remaining` の 2 フィールドのままである。

### 19.2 アイテム API

- `itemPool depth` は深度で制限した全カテゴリの種別を返す。巻物・杖・指輪の
  最小深度は `Item.idr` の `scrollMinDepth` / `wandMinDepth` / `ringMinDepth`。
- `makeItem` は装備の強化値・呪い、金の量、杖の充填数を RNG から決める。
  杖の充填数は `1d5 + 2`（3–7）。それ以外の `charges` は 0。
- `rollAppearances` はポーション 12 種、巻物 18 種、杖 14 種、指輪 14 種の
  固定名リストをそれぞれシャッフルし、合計 58 個の `(ItemKind, String)` を返す。
  `newGame` はレベル生成後にこれを 1 回だけ呼び、`Game.appearances` に保存する。
  固定フィクスチャは `itemAppearance` の固定表にフォールバックする。
- `appearanceOf` はランの外見を返す。`itemDisplayNameIn` / `itemDetailIn` は
  ゲームと UI が使うラン対応の名前・詳細で、`itemDisplayName` / `itemDetail` は
  固定外見表を使うテスト・フィクスチャ用のヘルパーとして残している。
- 識別は種別単位で `Game.knownKinds` に保持する。未識別の武器・防具・指輪は
  強化値と呪いを表示せず、未識別の杖は充填数を表示しない。金とアミュレットは
  常に既知である。

### 19.3 コマンドと効果

```idris
public export
data Command
  = Move Dir
  | Wait
  | Search
  | PickUp
  | Quaff ItemId
  | Read ItemId
  | Eat ItemId
  | Wield ItemId
  | Wear ItemId
  | PutOnRing ItemId
  | TakeOff ItemId
  | Drop ItemId
  | Throw ItemId Dir
  | Zap ItemId Dir
  | Descend
  | Ascend
```

巻物 18 種の効果:

| 種別 | 効果 |
|---|---|
| `ScrollConfuseMonster` | 現在の階層の全モンスターに `Confused 12` |
| `ScrollMagicMapping` | 現在の階層を全探索済みにする |
| `ScrollHoldMonster` | 全モンスターに `Held 10` |
| `ScrollSleep` | 全モンスターを `Asleep` にし、`Sleeping 20` を付与 |
| `ScrollEnchantArmor` | 装備中の防具の `enchant` を +1 し、AC を再計算 |
| `ScrollIdentifyPotion` | 所持する最初の未識別ポーションを識別 |
| `ScrollIdentifyScroll` | 所持する最初の未識別巻物を識別 |
| `ScrollIdentifyWeapon` | 所持する最初の未識別武器を識別 |
| `ScrollIdentifyArmor` | 所持する最初の未識別防具を識別 |
| `ScrollIdentifyRingOrWand` | 所持する最初の未識別指輪/杖を識別 |
| `ScrollScareMonster` | 読むと「You hear maniacal laughter in the distance.」だけ。床に置くとモンスターの侵入を防ぐ |
| `ScrollFoodDetection` | 同階の床の食料を探し、1 行動分の `DetectFood` を付けてマスを探索済みにする。対象がなければ未識別 |
| `ScrollTeleportation` | プレイヤーをランダムな歩行可能セルへ移動 |
| `ScrollEnchantWeapon` | 装備中の武器の `enchant` を +1 し、戦闘値を再計算 |
| `ScrollCreateMonster` | 隣接 8 マスから一様に選んでモンスターを 1 体生成。空きがなければ `FaintCry` |
| `ScrollRemoveCurse` | 所持品すべての `cursed` を False にする |
| `ScrollAggravateMonsters` | 全モンスターを `Chasing` にする |
| `ScrollProtectArmor` | 装備中の防具を `protected = True` にする |

装備中の防具/武器がない場合の強化・保護は警告を出し、ターンを消費しない。
識別系は対象がない場合も警告のみで、ターンを消費しない。

杖 14 種の効果:

| 種別 | 効果 |
|---|---|
| `WandLight` | 現在の階層を全探索済みにする |
| `WandInvisibility` | プレイヤーに `Invisible 20` |
| `WandLightning` / `WandFire` / `WandCold` | ビーム上の最初のモンスターに 6d6。魔法セーヴ成功時はダメージなし |
| `WandMagicMissile` | 同 1d4。魔法セーヴ成功時は消える |
| `WandPolymorph` | 対象を深度の出現プールからランダムな種別に変え、HP を振り直す |
| `WandHasteMonster` | 対象に `Hasted 20` |
| `WandSlowMonster` | 対象に `Slowed 20` |
| `WandDrainLife` | プレイヤー HP を半分にし、その半分を同じ部屋のモンスターで等分に与える |
| `WandNothing` | 「Nothing happens.」 |
| `WandTeleportAway` | 対象をランダムな歩行可能セルへ移動 |
| `WandTeleportTo` | プレイヤーをランダムな歩行可能セルへ移動 |
| `WandCancellation` | 対象に永続の `Cancelled` を付け、特殊攻撃・透明・擬態を無効化する。状態異常と行動状態は残す |

ビームは最大 8 セルで、壁・閉じたドアで止まり、最初のモンスターに当たる。
`lightning` / `fire` / `cold` / `magic missile` はダメージ判定の前に
`monsterMagicSave` を 1 回呼ぶ。`need = 17 - level / 2` に対し
`roll(1, 20) >= need` で成功し、成功時はダメージを振らない。
`lightning` / `fire` / `cold` のセーヴ成功は対象を `Chasing` にし、
`Held` を除く。`magic missile` の成功はメッセージだけを出す。
ドラゴンの火炎反射はセーヴ失敗時だけ判定する。
杖は 3–7 充填で始まり、振るたびに 1 充填を消費して種別を識別する。
充填 0 の杖は「The wand sputters.」で、ターンを消費せず識別もしない。

指輪 14 種の効果:

| 種別 | 効果 |
|---|---|
| `RingProtection` | AC に `1 + enchant` |
| `RingIncreaseDamage` | ダメージに `1 + enchant` |
| `RingIncreaseAccuracy` | 命中に `1 + enchant` |
| `RingDexterity` | 命中に +1（簡略化） |
| `RingAddStrength` | 実効筋力に +1 |
| `RingSustainStrength` | 列挙のみ。効果は未実装 |
| `RingSeeInvisible` | 透明なモンスターを見る |
| `RingStealth` | 眠っているモンスターの起床半径を半分にする |
| `RingRegeneration` | 3 ターンごとに HP を 1 回復（最大 HP 未満のとき） |
| `RingSlowDigestion` | 2 ターンごとに空腹を 1 回復 |
| `RingHunger` | 毎ターン空腹を追加で 1 減らす |
| `RingTeleportation` | 毎ターン 2% でランダムテレポート |
| `RingAggravateMonster` | 装備時に全モンスターを起こして追跡させる |
| `RingMaintainArmor` | 装備中の防具を錆びから守る |

指輪は左、右の順に装備する。両方埋まっている場合は「指が塞がっている」と
警告し、ターンを消費しない。呪われた指輪は外せない。装備すると種別を識別し、
AC・命中・ダメージ・筋力の派生値を再計算する。`RingDexterity` は原本の
筋力/敏捷の扱いを簡略化して命中 +1 にしている。

投げる:

- 装備中の武器・防具・指輪は投げられない（外すよう警告し、ターン消費なし）。
- 方向の先を最大 6 セルまで歩行可能セルでたどり、最初のモンスターで止まる。
- 武器は武器ダイス + `enchant` + 筋力ボーナス、それ以外は 1d2 のダメージ。
- ポーションは対象に当たると割れて消える。それ以外のアイテムは対象の手前、
  または経路の最後の歩行可能セルに落ちる。
- 投げると所持品から外れ、`ItemDropped` イベントを出す。1 ターンを消費する。

### 19.4 モンスターの状態異常

- `Monster.statuses` はプレイヤーと同じ `Status` を使う。
- モンスターターンの開始時に残りターンを 1 減らし、残り 1 以下になった状態は
  行動前に取り除く。
- `Held` / `Slowed` / `Paralyzed` / `Sleeping` は行動を飛ばす。
- `Confused` はランダムな隣接セルへ移動する。隣接していれば攻撃する。
- `Scared` はプレイヤーから最も遠い隣接セルへ逃げる。
- `Hasted` は 1 ターンに 2 回行動する。2 回目は更新後の位置と状態を再取得する。
- プレイヤーが `Invisible` のとき、隣接していないモンスターは追跡しない。
- 睡眠の巻物は `Asleep` と `Sleeping` を併用し、起床判定の直後に起きないようにする。

### 19.5 step の M4 での解決順

1. `Command` を検証し、プレイヤーの行動を解決する。
2. 巻物・杖・指輪・投げるの効果を適用する。杖は充填消費と識別を効果の前に、
   投げるはアイテムの移動をダメージの前に解決する。
3. モンスターの状態異常を 1 減らし、残っている状態に応じて行動または待機する。
4. 生存時間（状態異常の失効、毒、空腹、指輪の再生/消化/テレポート）を進める。
5. 死亡・勝利が確定していなければ FOV を再計算する。
6. レベル移動があったターンは、移動先のモンスターターンを省略する。

不正な操作（存在しない ID、装備中の物を投げる、空の杖、対象のいない強化巻物など）
は `turnConsumed = False` で返し、乱数を消費しない。

### 19.6 App / UI の追加

```idris
public export
data ItemAction
  = QuaffAction | ReadAction | EatAction | WieldAction | WearAction
  | PutOnAction | TakeOffAction | DropAction | ZapAction | ThrowAction

public export
data PendingDir
  = ZapDir ItemId
  | ThrowDir ItemId

public export
record Model where
  canvas : Canvas
  game : Game
  width, height : Len
  inventoryOpen : Bool
  selectedItem : Maybe ItemId
  inventoryIntent : Maybe ItemAction
  pendingDir : Maybe PendingDir
```

- `r/z/t/P/R/T` は所持品を開き、`inventoryIntent` に操作意図を保存する。
  アイテムを選ぶとその意図を即座に適用する。Enter はアイテムの既定動作。
- `ZapAction` / `ThrowAction` は所持品を閉じて `pendingDir` に移り、次の方向キーで
  `Zap` / `Throw` を発行する。Esc は `CancelDirection` で中止する。
- 再描画は `Ctrl-R` / `Ctrl-L`。`r` は巻物を読むキーになった。
- マップは巻物 `?`、杖 `/`、指輪 `=` を表示する。`DetectFood` 中は記憶済みの
  食料セルを暗いスタイルで表示する。
- インベントリは装備中の指輪に `*`、選択中のアイテムに `>` を付け、
  既知の杖は充填数、未識別品はランの外見名を表示する。ワイド画面のサイドバーは
  `Rings: 左 / 右` を表示する。
- 方向プロンプトは最新メッセージ行を置き換えて表示する。

### 19.7 テストと検証

- `tests/M4Test.idr`: 外見シャッフルの決定論、58 種の外見、深度プール、
  巻物 18 種の主要効果、杖 14 種の効果と充填、指輪の 2 枠と派生値、
  投げる、モンスター状態異常の行動規則。
- `tests/MapViewTest.idr`: `?` / `/` / `=` のグリフ、`DetectFood` による
  記憶済み食料の表示。
- `tests/SubsTest.idr`: `r/z/t/P` の所持品意図、方向キー、Esc キャンセル、
  `r` が巻物を読むキーであること。
- `tests/ViewTest.idr`: 指輪マーカー、既知の杖の充填数、未識別外見、
  ワイドサイドバーの指輪枠、方向プロンプト。
- `tests/PerfTest.idr`: 既存の Canvas / step 計測に加えて、
  `App.View` 全体（80x24、80x24 インベントリ、120x40）の描画を計測する。
- テストは `tests/TestRunner.idr` にまとめ、`lambda-rogue-tests.ipkg` で
  1 つの実行ファイルにビルドする。`tests/LambdaRogue` は
  `../src/LambdaRogue` へのシンボリックリンクで、テスト専用の
  `build/tests` に TTC を置く。`verify.sh` はメインパッケージと
  テストパッケージをビルドし、ランナーと PTY スモークテストを実行する。

### 19.8 M4 スライス 1 の既知の制約

- 巻物・杖・指輪の効果値、出現深度、充填数は暫定値であり、Rogue 5.4.4 の
  忠実性監査は M4 の残りで行う。
- `RingSustainStrength` は列挙のみで効果がない。`RingDexterity` は命中 +1 に
  簡略化している。
- 識別の巻物は指定カテゴリの最初の所持品を自動選択する。UI で対象を選ぶ
  ダイアログは未実装。
- モンスターはスライス 1 時点では 8 種だった。26 種、特殊能力、
  全トラップ効果はスライス 2 で追加した（§20）。
- 識別はアイテム個別ではなく種別単位。未識別フラグや「試した」履歴は持たない。
- 外見は `(ItemKind, String)` で保持する。セーブ・リプレイではこの対応表を
  そのまま保存する予定で、安定した `AppearanceId` はまだ導入していない。
- 杖の再充填、魔法の地図の永続化、ポーションの外見を含むセーブ、
  戦績、リプレイは未実装。

## 20. M4 実装ノート（2026-10-30、スライス 2）

M4 スライス 2 は A-Z 26 種のモンスター、特殊能力、プレイヤーの行動不能状態、
全トラップ効果を追加する。§19 の型を拡張し、モンスターがアイテムを所持できる
ようにした。数値と深度範囲は引き続き暫定値である。

### 20.1 型の差分

```idris
public export
data MonsterKind
  = Aquator | Bat | Centaur | Dragon | Emu | VenusFlytrap
  | Griffin | Hobgoblin | InvisibleStalker | Jackal | Kobold
  | Leprechaun | Medusa | Nymph | Orc | PurpleWorm | Quagga
  | Rattlesnake | Snake | Troll | UrVile | Vampire | Wraith
  | Xorn | Yeti | Zombie

public export
data MonsterAbility
  = PoisonBite | ConfusingGaze | HoldingAttack | FireBreath
  | RangedAttack | DrainLife | DrainExperience | RustArmor
  | StealGold | StealItem | Regenerate | Invisible
  | Erratic | Immobile

public export
record MonsterSpec where
  constructor MkMonsterSpec
  glyph : Char
  name : String
  level : Int32
  hpDice, hpSides : Int32
  damageDice, damageSides : Int32
  ac : Int32
  exp : Int32
  minDepth, maxDepth : Depth
  abilities : List MonsterAbility

public export
data ItemLocation
  = OnFloor Depth Coord
  | InPack
  | CarriedBy MonsterId
```

- `monsterSpec` は 26 種すべてを返す。`monsterName` / `monsterGlyph` と
  spec の名前・グリフは一致し、テストで一意性と A-Z の網羅を確認する。
- `hasAbility : MonsterAbility -> MonsterKind -> Bool` で能力を問い合わせる。
- `spawnPool` は深度範囲で絞り、該当がなければ `[Kobold]` を返す。
- `ItemLocation.CarriedBy` は窃取されたアイテムをモンスター個体に紐づける。

### 20.2 モンスター能力

- 毒・混乱・ホールド・ドレイン・装備錆・金/アイテム窃取は、命中ダメージの
  解決後に `monsterAbilityOnHit` が固定順で 1 つだけ適用する。
- 遠距離攻撃と炎は、`canSee` かつ距離 2–6 のときに `rangedStrike` を使う。
  隣接時は通常の `monsterStrike`。
- 再生はモンスターターンの開始時に最大 HP まで 1 回復する。
- 透明は `MapView` とサイドバーで、隣接するか `playerSeesInvisible` が真に
  なるまで隠す。`playerSeesInvisible` は `SeeInvisible` 状態または
  `RingSeeInvisible` で真になる。
- 不規則移動は隣接していなければランダムな空き隣接セルへ移動する。
- 不動は隣接時だけ攻撃し、移動しない。
- 盗まれたアイテムは `CarriedBy` になり、`dropCarriedBy` がモンスターの
  死亡時に最後の位置の床へ戻す。

### 20.3 プレイヤー状態とトラップ

- `Sleeping` / `Paralyzed`: `step` が全行動を消費し、
  `"You are asleep."` / `"You are paralyzed."` を出す。
- `Held`: `playerMove` は隣接モンスターへの攻撃だけ許可する。モンスターの
  いない方向へ移動を試みると `"You are held in place."` を出して 1 ターン消費する。
- トラップ効果:
  - `TrapDoor`: 深度 26 以外なら次階層へ落下。深度 26 では 1d6 ダメージ。
  - `Arrow`: 1d4、`Dart`: 1d3。
  - `Bear`: `Held 3` と 1d6 ダメージ。
  - `Sleep`: `Sleeping 10`。
  - `Teleport`: ランダムな歩行可能セルへ移動。
  - `Rust`: 装備中の防具の強化値を 1 下げる。保護または
    `RingMaintainArmor` があれば防ぐ。
  - `Mysterious`: 1d5 で睡眠・混乱・盲目・毒・テレポートのいずれか。
- 錆処理は `rustPlayerArmor` に集約し、トラップと Aquator の能力で共有する。

### 20.4 step の解決順

§19.5 と同じ。モンスターターンでは各モンスターの状態異常を 1 減らし、
再生を適用してから行動する。死亡したモンスターの所持品は、経験値付与より前に
床へ落とす。

### 20.5 テストと検証

- `tests/DungeonTest.idr`: 26 種、名前/グリフの一意性、A-Z 網羅、
  spec とヘルパーの一致、能力の重複なし、代表的な能力割当、深度プール。
- `tests/M4Test.idr`: 各能力（毒、混乱、ホールド、ドレイン、経験値ドレイン、
  錆、金/アイテム窃取、ドロップ、再生、遠距離、炎、不動）、
  プレイヤーの睡眠/麻痺/ホールド、睡眠/熊/ダーツ/錆/不思議トラップ。
- `tests/MapViewTest.idr`: 透明ストーカーの非表示、隣接、
  `SeeInvisible`、指輪による開示。
- `tests/CombatTest.idr` / `tests/CoreTest.idr`: フィクスチャを `Kobold` に更新。

### 20.6 M4 スライス 2 の既知の制約

- 26 種の HP・ダメージ・AC・経験値・深度範囲は暫定値。忠実性監査で置き換える。
- 毒は `Poisoned` 状態のターンダメージ、ドレインは最大 HP/経験値の減少として
  簡略化している。原本のレベルドレインや能力値ドレインは未実装。
- 透明は「隣接で見える」簡略化。原本の透明判定やサーチとの関係は監査対象。
- 群れ、睡眠確率、起床条件、逃走確率、深度ごとの出現重みは未実装または固定。
- トラップの作動確率・持続・深度別出現表は暫定。

## 21. M4 実装ノート（2026-10-31、スライス 3）

M4 スライス 3 は Core のゲーム規則を変えず、`App.Model`、`App.Update`、
`App.Subs`、`App.View`、`UI.MapView` にモダン UX を追加する。

### 21.1 App の状態

```idris
public export
data LogFilter
  = AllMessages | CombatMessages | ItemMessages
  | SystemMessages | WarningMessages

public export
record PaletteEntry where
  constructor MkPaletteEntry
  label : String
  hint : String
  action : Msg

public export
record Model where
  constructor MkModel
  canvas : Canvas
  game : Game
  width, height : Len
  inventoryOpen : Bool
  selectedItem : Maybe ItemId
  inventoryIntent : Maybe ItemAction
  pendingDir : Maybe PendingDir
  helpOpen : Bool
  paletteOpen : Bool
  paletteIndex : Nat
  logFilter : LogFilter
```

- `LogFilter` と `messageMatches` は表示専用である。`Game.messages` の内容や
  順序、ターン、乱数には触れない。
- `PaletteEntry.action` は通常の `Msg` である。`PaletteExecute` は
  `update entry.action` を呼ぶだけで、キーボードと同じ更新経路を通る。
- ヘルプ、パレット、インベントリは排他。開く操作は他のオーバーレイを閉じ、
  方向プロンプトも解除する。
- `initModel` の初期値は `helpOpen = False`, `paletteOpen = False`,
  `paletteIndex = 0`, `logFilter = AllMessages`。

### 21.2 入力

- 通常時: `?` / `F1` → ヘルプ、`Ctrl-P` → パレット、`F2` → ログフィルタ循環。
- ヘルプ表示中: Esc、`?`、F1、`q` で閉じる。他のキーは無視する。
- パレット表示中: Up/`k`、Down/`j` で移動、Enter で実行、Esc / `Ctrl-P` で閉じる。
  他のキーは無視する。
- `Ctrl-C` はオーバーレイ表示中でも終了する。
- 方向プロンプトとインベントリの既存ルーティングは、オーバーレイが
  開いていないときだけ評価する。

### 21.3 表示

- ワイド表示はヘッダ 1 行、メイン 30 行、ログ 8 行、ステータス 1 行。
  メイン左 80 列はマップ 80x22 と 36x8 ミニマップ、右 40 列はサイドバー。
- ミニマップは各ブロックの中心タイルを表示し、探索済みの階段とプレイヤーを
  座標から上書きする。未探索は空白、モンスター・アイテム・トラップは出さない。
- ワイドのログは `logFilter` に一致する直近 8 件を古い順に表示する。
  ヘッダにフィルタ名を出す。クラシックの最新行もフィルタに従い、
  all 以外では `[combat]` などの接頭辞を付ける。
- ワイドインベントリは左に一覧、右に詳細パネルを置く。詳細は表示名、
  スロット、カテゴリ、装備位置、強化値、呪い、既知の充填数、保護状態、
  装備中アイテムとの比較を出す。未識別の効果は表示しない。
- ヘルプは 80x24 では 18 行、120x40 では記号表と目標を加えた 24 行。
  パレットは 16 項目を選択マーカー付きで表示する。

### 21.4 テストと検証

- `tests/MapViewTest.idr`: ミニマップの行数・幅、プレイヤー、階段、
  未探索の非表示、モンスターの非表示、サイズ変更。
- `tests/SubsTest.idr`: `?`/F1/`Ctrl-P`/`F2`、ヘルプとパレットの閉じ方、
  オーバーレイ中の移動キー無視、パレットの移動・実行、フィルタ更新。
- `tests/ViewTest.idr`: ヘルプ（クラシック/ワイド）、パレット、
  ログフィルタ（クラシック/ワイド）、ミニマップ凡例、インベントリ詳細。
- `tests/PerfTest.idr`: 既存の 80x24 / 120x40 描画計測を継続する。

### 21.5 M4 スライス 3 の既知の制約

- パレットは固定 16 項目で、テキスト入力による絞り込みはまだない。
- ヘルプはキーマップ設定から生成せず、現行キーの静的リストである。
- オーバーレイの背景は暗くせず、中央にパネルを置くだけである。
- マウス、アニメーション、キーバインド変更は M4 の残り
  （テーマはスライス 5 で実装済み）。
- ログの折り返し・スクロールバック・同一メッセージの集約は未実装。
- インベントリのフィルタ・ソート・検索・数量指定は未実装。

## 22. M4 実装ノート（2026-10-31、スライス 4）

M4 スライス 4 は、ゲーム終了時の戦績、コマンド列からのリプレイ検証、
seed 共有を追加する。ゲーム規則と乱数消費順序は変えない。

### 22.1 `Core.Replay`

```idris
public export
record Replay where
  constructor MkReplay
  seed : Bits64
  commands : List Command   -- 新しい順

public export
emptyReplay : Bits64 -> Replay
public export
recordCommand : Command -> Replay -> Replay
public export
replayCommands : Replay -> List Command
public export
runReplay : Replay -> Game
public export
gameDigest : Game -> String
public export
replayMatches : Replay -> Game -> Bool
```

- `recordCommand` は先頭に追加する。`replayCommands` が `reverse` して
  実行順に戻す。
- `runReplay` は `newGame r.seed` から `step` を順に適用する。
  App が `newGame` 以外の状態（将来のセーブ復元）から始めた場合は、
  その状態を再現できないため `replayMatches` は不一致になる。
- `gameDigest` は `Game.messages` を除く状態の FNV-1a 64-bit。
  seed、RNG 状態、ターン、深度、プレイヤー、全訪問階層、アイテム、
  ID 採番、識別済み種別、外見表、終了状態、視界を含む。
  16 文字の小文字 hex を返す。
- `seedHex : Bits64 -> String` は `Core.Rng` にあり、16 文字に zero-pad
  した seed を返す。`stateHex` と同じ `Text.NumberFormat.toHex` を使う。
- `Core.Replay` は `IO`、`termui`、ファイル、時計を import しない。

### 22.2 App の状態と更新

```idris
public export
record Score where
  constructor MkScore
  seed : Bits64
  depth : Depth
  level : Int32
  exp : Int32
  gold : Int32
  turns : Turn
  result : GameOver

public export
scoreOf : Game -> Maybe Score
```

`Model` に `replay : Replay`、`scores : List Score`、`scoreOpen : Bool`、
`shareOpen : Bool`、`replayOk : Maybe Bool` を追加する。`initModel` は
`emptyReplay g.seed`、空の戦績、閉じたオーバーレイ、`Nothing` で始まる。

- `runCommand` は `step` の前にコマンドを記録する。ゲームが既に終了して
  いれば何もせず、記録もしない。
- `step` の結果が `over = Just _` になったら、`scoreOf` の値を戦績の先頭に
  追加し、`replayMatches` を一度だけ評価して `replayOk` に保存する。
  同時にスコア画面を自動で開く。
- `OpenScores` / `OpenShare` は他のオーバーレイと方向プロンプトを閉じる。
  `CloseScores` / `CloseShare` は対応するフラグだけを下ろす。
- `CopySeed` は `SetClipboard (seedHex m.game.seed)` を返す。

### 22.3 入力と表示

- 通常時: `S` → スコア、`Ctrl-S` → シード共有。
- スコア表示中: Esc、`S`、`q`、Enter で閉じる。他のキーは無視する。
- シード共有中: `c` / `C` / Enter でコピー、Esc / `Ctrl-S` / `q` で閉じる。
- `Ctrl-C` はどのオーバーレイでも終了する。
- パレットは 18 項目。`Scores`（`S`）と `Share seed`（`Ctrl-S`）を
  `Quit` の前に追加した。クラシック 80x24 ではタイトル 1 行 + 18 項目 +
  ヒント 1 行が枠内 20 行に収まる。
- スコア画面は新しい順に最大 8 件を表示し、seed と
  `Replay: verified` / `Replay: MISMATCH` / `Replay: not checked` を出す。
- シード共有画面は 16 文字の seed、深度、レベル、ターン、記録済み
  コマンド数、リプレイ検証結果、コピー方法を表示する。
- ヘッダとサイドバーの seed も `seedHex` の 16 文字表記に揃えた。

### 22.4 テストと検証

- `tests/ReplayTest.idr`: `seedHex` の長さと zero-pad、記録順、
  `newGame` との一致、手動実行との一致、余分なコマンドと別 seed の不一致、
  digest の決定性、`scoreOf` の未終了/勝利/死亡。
- `tests/SubsTest.idr`: `S` / `Ctrl-S`、スコア・共有の閉じ方、
  オーバーレイ中のキー無視、パレット 18 項目、終了時のスコア自動表示、
  終了後のコマンド無視。
- `tests/ViewTest.idr`: スコア画面の一覧・seed・検証結果・不一致表示、
  共有画面の seed・コマンド数・コピー説明。
- `tests/PerfTest.idr`: スコア画面と共有画面の描画時間を追加。

### 22.5 M4 スライス 4 の既知の制約

- スライス 4 時点では戦績はメモリ上だけだった。スライス 10 で
  `scores.jsonl` への追記と起動時の読み込みを追加した（§28）。
- スライス 4 の時点では可視リプレイ再生は未実装だった。スライス 8 で
  速度変更・一時停止・1 コマンド送り・再開・最初からの再生を追加した。
  途中チェックポイントとシークはまだない。
- スコアの並び替え、名前入力、殺害数、日時、死因の詳細表示は未実装。
- `gameDigest` は暗号学的ハッシュではない。改ざん検出ではなく、
  同一 seed とコマンド列の再現性確認に使う。
- メッセージ列の digest はまだ持たない。状態 digest のみを比較する。

## 23. UI テーマ（2026-11-01、スライス 5）

テーマは表示だけの関心事で、Core には存在しない。

### 23.1 型と変換

`LambdaRogue.UI.Theme` が `Theme` と `StyleRole` を公開する。

- `Theme = ClassicCga | ModernDark | Amber | GreenPhosphor | HighContrast |
  ColorblindSafe | Monochrome`
- `StyleRole` は背景、本文、タイトル、ヘッダ、警告、枠、ミニマップ、
  地形（岩・床・通路・ドア・階段）、モンスター、アイテム、トラップ、
  プレイヤー、メッセージ種別などの意味スロット。
- `styleFor : Theme -> StyleRole -> Style`
- `messageStyleFor : Theme -> MessageKind -> Style`
- `themes`, `nextTheme`, `themeId`, `themeFromId`
- `ColourSupport = NoColour | AnsiColour | TrueColour`
- `detectColourSupport`, `detectReducedMotion`, `themeForSupport`

Classic CGA はスライス 4 までの ANSI 色と一致する。他テーマは
`Indexed` または `RGB` を使う。`MapView` は `cellForIn` / `mapCellsIn`、
`App.Canvas` は `drawMapIn` を提供し、既存の `cellFor` / `mapCells` /
`drawMap` は Classic CGA の別名として残す。

### 23.2 App の状態

`Model.theme : Theme` を末尾に追加する。`initModel` は `ClassicCga`。
`CycleTheme` は `nextTheme` で進め、`drawMapIn` で Canvas を再描画する。
`F3` はオーバーレイ表示中でも効く。スライス 5 の時点でパレットは
19 項目になり、`Scores` / `Share seed` の後、`Quit` の前に
`Cycle theme` を置いた。スライス 7 で `Toggle animation` を加えて 20 項目。

テーマ変更は `Command` ではないため、`Replay` に記録されず、
`gameDigest` にも含まれない。`F3` はターンを消費せず、乱数も消費しない。

### 23.3 テスト

- `tests/ThemeTest.idr`: 7 テーマの一意性、巡回、Classic の既存スタイルとの
  一致、テーマ別マップセル、メッセージスタイル、ヘッダの実描画スタイル、
  テーマ変更がゲーム状態を変えないこと。テーマ ID の往復、色能力の検出、
  モノクロへのフォールバック、モノクロが属性だけを使うこと。
- `tests/SubsTest.idr`: `F3`、オーバーレイ中の `F3`、パレット項目、
  `CycleTheme` の更新。
- `tests/ViewTest.idr`: ヘッダのテーマ名、ヘルプの `F3`、パレットの
  `Cycle theme`。
- `tests/PerfTest.idr`: Modern Dark の 120x40 描画。

### 23.4 端末能力とフォールバック（M5 スライス 3）

- `detectColourSupport : Maybe String -> Maybe String -> Maybe String
  -> ColourSupport` は `NO_COLOR`, `COLORTERM`, `TERM` を受け取る。
  空でない `NO_COLOR` と `TERM=dumb` は `NoColour`、
  `COLORTERM=truecolor|24bit` は `TrueColour`、それ以外は `AnsiColour`。
- `themeForSupport` は `NoColour` なら常に `Monochrome`、`AnsiColour` なら
  RGB テーマを `ClassicCga` / `HighContrast` へ落とす。`TrueColour` は
  要求テーマをそのまま返す。
- `Monochrome` は前景・背景色を持たず、太字・下線・反転・淡色だけで
  役割を区別する。ゲームのグリフは ASCII のまま。
- `Main` は `--no-color` を `NO_COLOR` と同じ扱いにし、`--theme` が
  あれば設定より優先してから `themeForSupport` に通す。どちらも
  設定ファイルを書き換えない。
- `detectReducedMotion` は `NO_MOTION` を同じ規則で判定する。

### 23.5 既知の制約

- テーマごとのグリフ変更（ASCII/Unicode）はまだない。色と属性だけを変える。
- `--theme` で指定したテーマが端末能力で降格された場合、その旨は
  起動後に明示しない。ヘッダには実際に使っているテーマ名を出す。

## 24. マウス（2026-11-02、スライス 6）

マウスは表示と入力の都合であり、Core には存在しない。`App.Mouse` が
端末の物理座標を画面レイアウト座標とゲーム座標へ変換し、キーボードと
同じ `Msg` に落とす。そのため Core の `Command`、乱数消費順、ターン、
リプレイ、`gameDigest` はマウスの有無で変わらない。

### 24.1 レイアウト座標

- `layoutSize : Model -> (Len, Len)` は `App.View.view` が選ぶ
  トップレベルレイアウトの寸法を返す。80x24 未満では画面全体、
  ヘルプは 100x32 / 80x24、パレットは 90x32 / 78x22、リプレイ一覧は
  90x30 / 78x24、スコア・シェアは 90x30 / 78x24、通常とインベントリは
  120x40 / 80x24。
- `layoutOrigin : Model -> (Len, Len)` は中央寄せの左上オフセット。
- `mapCellAt : Model -> Len -> Len -> Maybe Coord` は通常マップの
  セルを返す。マップはクラシックでは最新メッセージ行の下、ワイドでは
  ヘッダ行の下から始まるため、どちらもレイアウト上端 + 1 行を引く。
  オーバーレイ表示中や画面が 80x24 未満のときは `Nothing`。
- `isWideScreen` は `width >= 120 && height >= 40`。これは `View` の
  ワイド判定と同じ条件で、マウス側だけ判定がずれないようにしている。
- 端末座標は `MouseEvent.column` / `MouseEvent.row`（0 始まり、`Len`）。
  `Len` の引き算は負になり得るため、各判定で 0 以上を確認する。

### 24.2 メッセージ変換

`mouseMsg : Model -> MouseEvent -> Maybe Msg` が唯一の入口で、
`App.Subs` の `OnMouse` から呼ばれる。`Msg` を返さないイベントは
状態を変えない。

- 通常画面のマップ左クリック: クリック先が探索済みなら、プレイヤーから
  そのセルへの 1 歩の `Do (Move d)`。隣接モンスターなら Core が攻撃に
  解決する。自分のセルなら床のアイテムを `Do PickUp`、上下階段なら
  `Do Ascend` / `Do Descend`。未探索セルとマップ外は無視する。
- 方向プロンプト中（`pendingDir`）: 同じクリックが `Do (Zap iid d)` または
  `Do (Throw iid d)` になる。方向は `directionTo` の 8 方向。
- マップの移動/ドラッグ: `HoverCell (mapCellAt ...)`。マップ外は
  `HoverCell Nothing`。ホバーは `App.Model.hover` を更新するだけで、
  ターンも乱数も消費しない。
- ログ領域のホイール: クラシックは最新メッセージ行、ワイドは
  31〜38 行目。下回しで `CycleLogFilter`、上回しで
  `CycleLogFilterBack`。
- インベントリ: 行クリックで `SelectItem`、ダブルクリックで
  `ActOnItem (defaultAction i)`、`inventoryIntent` 付きなら 1 クリックで
  そのアクション。ホイールは前後の `SelectItem`、パネル外クリックと
  右クリックは `CloseInventory`。
- パレット: 行クリックで `PaletteSelect`、ダブルクリックで
  `PaletteRun`、ホイールで `PalettePrev` / `PaletteNext`、
  パネル外・ヒント行・右クリックで `ClosePalette`。
- ヘルプとスコア: 左/右クリックで閉じる。シェア: コピー行で
  `CopySeed`、閉じる行・パネル外・右クリックで `CloseShare`。

`inventorySlotAt` はクラシックの左右 2 列（左が 0〜19、右が 20〜39）と
ワイドの 1 列を扱う。`App.Model.defaultAction` は Enter キーと
ダブルクリックで共有し、両者が同じ既定動作になるようにしている。

### 24.3 表示

`UI.MapView.describeCell : Game -> Coord -> Maybe String` は、未探索なら
`Nothing`、探索済みなら地形名と、そのセルに見えているモンスター・
アイテム・発見済みトラップを返す。`MapView.highlightCell` はホバー中の
セルに `Inverse` を足し、`App.Canvas.drawMapWith` がテーマとホバーを
受け取って描く。ホバー中は最新メッセージ行の代わりにツールチップを
出すが、ログ本体とゲーム状態は変えない。

### 24.4 テスト

- `tests/MouseTest.idr`: 80x24 / 100x30 / 120x40 の座標変換、
  マップクリック、方向プロンプト、自分のセルの拾い上げと階段、
  インベントリの 2 列・意図付きクリック・ホイール、
  パレット・ヘルプ・スコア・シェア、ログホイール、ホバー強調と
  ツールチップ、ホバーがターンとリプレイを変えないこと。
- `tests/SubsTest.idr`: `OnMouse` の常時購読と `CycleLogFilterBack`。
- `tests/ViewTest.idr`: ホバー時のツールチップとヘルプのマウス説明。
- `tests/PerfTest.idr`: 通常・インベントリ・ワイド・テーマ・
  オーバーレイの描画時間。マウス経路は描画を追加しない。

### 24.5 既知の制約

- termui はボタン/ドラッグ追跡（1002）を使うため、通常のホバーを
  送らない端末では、移動やドラッグをしないとツールチップが更新されない。
- 右クリックはオーバーレイを閉じるだけ。コンテキストメニュー、
  長押し、ドラッグによる連続移動は未実装。
- 階段クリックの確認、`MouseFocus` によるウィジェットフォーカス、
  マウス設定の保存は未実装。キーボードだけで全操作できる状態を保つ。

## 25. アニメーション（2026-11-02、スライス 7）

アニメーションは表示だけの関心事で、Core の `Game` も `step` も変更しない。
`Outcome.events` を入力に、`UI.Animation` が短命の `Effect` を作り、
`App.Model.animations` に保持する。

### 25.1 型

`LambdaRogue.UI.Animation` が公開するもの:

- `EffectKind = Trail | Impact | Damage Int32 | Death | Pickup |
  DoorMark | TrapMark | LevelUpMark | Victory`
- `Effect`（`kind`, `pos`, `age`, `life`）
- `AnimationSpeed = SlowAnimation | NormalAnimation | FastAnimation`
- `animationDelay : AnimationSpeed -> Nat`（32 / 16 / 8 ms）
- `nextAnimationSpeed`, `animationSpeedId`, `animationSpeedFromId`
- `mkEffect : EffectKind -> Coord -> Effect`
- `effectsFor : Game -> Game -> List Event -> List Effect`
- `advanceAnimations : List Effect -> List Effect`
- `mergeAnimations : List Effect -> List Effect -> List Effect`
- `effectCells : List Effect -> List (Int32, Int32, Char, StyleRole)`

`life` は 16ms ティック数。移動・攻撃・拾い上げ・ドアは 4、
ダメージ数字とトラップは 12/8、死亡は 8、レベルアップは 10、勝利は 16。
`effectsFor` はステップ前の `Game` から残像・倒したモンスターの位置を、
ステップ後の `Game` から落下アイテムや死亡位置を取る。

### 25.2 App の状態と更新

`Model` の末尾に `animations : List Effect` と
`animationsEnabled : Bool`（初期値 `True`）を追加する。

- `runCommand` は `step` の `events` から効果を作り、
  `mergeAnimations` で最大 24 個まで保持する。無効時は作らない。
- `AnimationTick` は `advanceAnimations` で 1 ティック進め、
  マップ表示中なら Canvas を再描画する。すべて消えたらタイマーは止まる。
- `subs` は `animations` が空でないときだけ
  `Every "animation" (animationDelay m.ui.animationSpeed) AnimationTick`
  を追加する。速度は `Model.ui.animationSpeed` にあり、表示専用である。
- `ToggleAnimations` は `F4` とパレットの `Toggle animation` から届く。
  無効にすると現在の効果も消す。
- `App.Canvas.drawMapAnimated` がマップの後に効果を描く。既存の
  `drawMapWith` / `drawMapIn` / `drawMap` は効果なしの別名として残す。
- `effectCells` は効果を古い順に返し、同じセルでは新しい効果が勝つ。
  ダメージ数字は複数桁を横に並べ、80x22 の外へは描かない。

### 25.3 テスト

- `tests/AnimationTest.idr`: イベント別の位置と種類、複数桁ダメージ、
  右端クリップ、ティックによる加齢と消滅、24 個の上限、新しい効果の
  優先、無効時の効果なし、速度の巡回とティック間隔、アニメーション有無で
  ターンとリプレイが一致すること。
- `tests/SubsTest.idr`: `F4`、オーバーレイ中の `F4`、アニメーション中だけ
  `Every` が購読されること。
- `tests/ViewTest.idr`: ヘルプの `F4` とパレットの `Toggle animation`。

### 25.4 既知の制約

- 移動の補間、投射物の飛翔、視界のフェードは未実装。現在はセル単位の
  残像・記号・数字だけ。
- 速度は slow/normal/fast の 3 段階（32 / 16 / 8 ms）。`NO_MOTION` と
  `--no-animation` は起動時にアニメーションを無効化する。無効化は
  `F4` / パレット / `settings.json` の `animation` でも行える。
- アニメーションは 1 ターン分のイベントをまとめて出す。イベント間の
  順序再生や、複数ターンのキューイングはまだない。

## 26. 可視リプレイ再生（2026-11-02、スライス 8）

可視再生は App の表示状態だけで、Core のリプレイ形式や検証結果を変えない。
`App.Model.playback` が再生を所有し、表示中だけ `Model.game` を再生用の
ゲームに差し替える。元のゲームは `Playback.original` に保持する。

### 26.1 型

`LambdaRogue.App.Model` が公開するもの:

- `PlaybackSpeed = SlowPlayback | NormalPlayback | FastPlayback`
- `playbackDelay : PlaybackSpeed -> Nat`（400 / 200 / 80 ms）
- `fasterPlayback`, `slowerPlayback`
- `Playback`（`original`, `replay`, `remaining`, `played`,
  `commandCount`, `playing`, `speed`, `done`, `verified : Maybe Bool`,
  `returnToScores`）
- `playbackOpen : Model -> Bool`

`remaining` は `replayCommands` の順（古いコマンドが先頭）。`replay` は
記録済みの `Replay` をそのまま参照し、再生中に `recordCommand` しない。

### 26.2 開始と更新

- スコア画面で `P` を押すと `StartReplay`。`scoreOpen` を閉じ、
  `game := newGame replay.seed`、`remaining := replayCommands replay` にする。
  `verified` は `replayOk` を引き継ぐ。
- `F5` / パレットの `Replay browser` は `OpenReplayBrowser` を出し、
  `listReplayFiles` の結果を `ReplayFiles` で `Model.ui` に入れる。
  `ReplayBrowserNext` / `Prev` / `Select` は選択位置だけを変え、
  `ReplayBrowserOpenSelected` が `loadReplayFile` を `Perform` する。
  `ReplayFileLoaded` は成功なら `beginPlayback r Nothing`、失敗なら
  `ui.replayError` を立てる。ファイルから読んだリプレイは未検査で始まる。
- `ReplaySeekBack` / `Forward` は 10 コマンド、`ReplaySeekStart` / `End` は
  0 / `commandCount` を目標に `seekPlayback` を呼ぶ。`seekPlayback` は
  seed から prefix を `step` で再実行して `remaining` と `game` を作り、
  再生を一時停止する。`Replay` 自体は変更しない。
- `ReplayTick` は 1 コマンドだけ `step` し、`played` を進める。
  `remaining` が空になるか `game.over` になったら `done := True`,
  `playing := False`。
- `ReplayStep` は一時停止中でも 1 コマンド進める。
- `ReplayToggle` は Space の一時停止/再開。`ReplaySpeedUp` /
  `ReplaySpeedDown` は速度を上下限付きで変える。
- `ReplayRestart` は `newGame replay.seed` に戻して最初から再生する。
- `CloseReplay` は `Playback.original` を `game` に戻す。
  `returnToScores` は開始時にスコア画面が開いていたかを保持し、
  スコア画面から始めた再生だけスコア画面へ戻る。一覧から通常プレイ中に
  始めた再生はマップへ戻る。
- `subs` は再生中かつ `playing` かつ残りがあるときだけ
  `Every "replay" (playbackDelay speed) ReplayTick` を追加する。
- `runCommand` と `mouseMsg` は `playbackOpen` の間は入力を処理しない。
  `F3` テーマと `F4` アニメーションだけは共通の先頭節で引き続き使える。

再生中の `step` は `Replay` に記録しないため、`replay.commands` と
`gameDigest` は開始前のまま不変である。

### 26.3 表示

通常の 80x24 / 120x40 レイアウトを使い、`Model.game` が再生用ゲームなので
マップ、サイドバー、ログ、ステータスはそのまま追従する。最上段は
`REPLAY n/N [####------] speed state verification` に置き換える。
`state` は `playing` / `paused` / `complete`、`verification` は
`not checked` / `verified` / `MISMATCH`。リプレイ一覧はタイトル、
ファイル名の選択行、操作説明を出し、空なら
`No saved replays.` を表示する。

### 26.4 テスト

- `tests/PlaybackTest.idr`: 初期状態、1 コマンド進行、カウンタ、
  一時停止中のティック無視、再開、速度変更、再スタート、完走時の
  記録状態との一致と検証、シークの前後移動とクランプ、リプレイ一覧の
  選択・巡回・壊れたファイル、読み込み時の未検査状態、終了時の元ゲーム
  復元、空リプレイ。
- `tests/SubsTest.idr`: スコア画面の `P`、`F5` の一覧、再生中のタイマー、
  Space、シークキー、Esc、再生中の通常キー抑止、一時停止時のタイマー停止。
- `tests/MouseTest.idr`: 再生中のクリック無視。
- `tests/ViewTest.idr`: スコア画面の再生案内、進捗バー付き `REPLAY` 表示、
  未検査表示、リプレイ一覧と空一覧。

### 26.5 既知の制約

- 状態スナップショット型の途中チェックポイントは未実装。シークは毎回
  seed から prefix を再実行するため、長いランでは先頭ほど時間がかかる。
- 再生速度は 3 段階の固定値。フレーム単位の補間や可変速度はない。
- 再生中はログスクロールとアイテム詳細表示を提供しない。マウスは
  再生画面ではなくリプレイ一覧の選択・実行だけを補助する。

## 27. キーマップと設定（2026-11-02、スライス 9）

設定は表示と入力のためだけに存在する。Core は `Keymap` も `Settings` も
import せず、キー変更が `Command`、ターン、RNG、`Replay`、`gameDigest` に
影響することはない。

### 27.1 型

`LambdaRogue.App.Keymap`:

- `KeyChord`（`key : Key`, `mods : Mods`）。文字キーは大文字小文字を区別し、
  `Ctrl-` / `Alt-` 付きの文字は端末差を吸収するため小文字に正規化する。
  Shift は文字そのもの（`Q`）で表し、修飾子としては保持しない。
- `CommandId`: `MoveNorth` ... `Quit` の安定した識別子。
  `Show` はデバッグ用、`commandName` / `commandFromName` は
  `settings.json` 用の文字列（`move-north`, `pick-up`, `put-on-ring` など）。
- `Binding`（`id`, `label`, `keys`）と `Keymap = List Binding`。
- `defaultKeymap`、`bindingFor`、`keysFor`、`setBindingKeys`、
  `commandForChord`、`hasDuplicateChords`、`chordText`、`formatKeys`、
  `formatPrimary`、`parseKeyChord`、`anyArrowKeys`。

`LambdaRogue.App.Settings`:

```idris
public export
record Settings where
  constructor MkSettings
  theme : Theme
  animationsEnabled : Bool
  animationSpeed : AnimationSpeed
  keymap : Keymap
  language : Language

public export
defaultSettings : Settings
settingsSchema : String
settingsSchema = "lambda-rogue.settings.v1"
```

`settingsFromJSON` / `settingsFromText` は純粋で、`settingsToJSON` /
`settingsToText` が書き込み用の値を返す。

### 27.2 `settings.json`

```json
{
  "schema": "lambda-rogue.settings.v1",
  "theme": "modern-dark",
  "animation": true,
  "animationSpeed": "normal",
  "language": "en",
  "keys": {
    "move-north": ["k", "Up"],
    "inventory": ["i"],
    "help": ["?", "F1"],
    "quit": ["Q", "Ctrl-C"]
  }
}
```

- `schema` は必須。未知のスキーマはファイル全体を拒否する。
- `theme` / `animation` / `animationSpeed` / `language` は省略可能で、
  既定は `classic-cga` / `true` / `normal` / `en`。
- `animationSpeed` は `slow`, `normal`, `fast` のいずれか。未知の値は
  ファイル全体を拒否する。`--no-animation` と `NO_MOTION` はこの値より
  優先して、その起動だけアニメーションを止める。
- `language` は `en` / `ja`。未知の値は `en` にフォールバックする。
  `--lang` はその起動だけ上書きする。
- `theme` の未知の ID はファイル全体を拒否する。`--theme` と
  `--no-color` はその起動だけ上書きし、保存はしない。
- `keys` の値は 1 つのコード文字列、またはコード文字列の配列。
  空配列はそのコマンドを未割り当てにする。
- 未知のコマンド ID は無視する。既知の ID の値が壊れている場合、
  または同じコードが 2 つのコマンドに割り当てられた場合はファイル全体を
  拒否し、既定値にフォールバックする。
- コードは 1 文字（`k`, `Q`, `>`）、`Ctrl-S`、`Alt-X`、`F1`〜`F12`、
  `Up` / `Down` / `Left` / `Right`、`Home` / `End` / `PageUp` / `PageDown`、
  `Insert` / `Delete`、`Enter` / `Tab` / `Backspace` / `Esc`、`Space` を
  受け付ける。
- ファイルは `$XDG_DATA_HOME/lambda-rogue/settings.json`、環境変数が
  なければ `$HOME/.local/share/lambda-rogue/settings.json`。
  `Persist.Settings` の `loadSettings` / `saveSettings` が IO を担当する。
  保存は現在、同一ディレクトリの一時ファイル + rename ではなく直接書き込み
  である（base に rename がないため）。失敗時は `IO Bool` で false を返す。
- テーマ巡回とアニメーション切替は設定を自動保存する。キーマップは
  パレットの `Save settings` で保存し、`Reload settings` で読み直す。

### 27.3 入力ルーティング

- 通常プレイ、インベントリ、方向プロンプトは `Model.keymap` の
  `commandForChord` で `CommandId` を求め、既存の `Msg` に変換する。
  したがってキー変更は UI の入力経路だけを変え、Core のコマンド列は
  同じ意味のままである。
- ヘルプ、パレット、スコア、シェア、再生画面の閉じるキーなどは、
  それぞれの画面が持つ小さな固定キー集合を使う。これは画面内の
  ナビゲーションであり、ゲームコマンドではない。
- `F3`（テーマ）、`F4`（アニメーション）、`F5`（リプレイ一覧）は
  オーバーレイ中も共通の先頭で処理する。`F5` は再生中だけ無視する。
  `Ctrl-C` は再生中も含めて緊急終了として最優先で扱う。
- 既定キーは `q` = ポーション、`Q` / `Ctrl-C` = 終了、`i` = インベントリ、
  `?` / `F1` = ヘルプ、`Ctrl-P` = パレット。通常プレイの Esc は終了しない。

### 27.4 表示

- ヘルプの移動・アイテム・UI 行は `helpLines : Keymap -> List String` が
  有効なキーマップから生成する。移動キーは 8 方向の主キーを並べ、
  矢印が 1 つでも割り当てられていれば `/ arrows` を添える。
- パレットの `hint` は `paletteEntriesFor : Keymap -> List PaletteEntry` が
  `formatPrimary` で生成する。固定のヒント文字列は持たない。
- パレットは 28 項目。`Cycle animation speed` は現在の速度
  （`slow` / `normal` / `fast`）をヒント列に出す。`Replay browser` は
  `F5` を持つ。`Save settings` / `Reload settings` / `Save and quit` /
  `Load game` はキーを持たない項目として 22〜25 番目に置き、
  `Search for traps` が 26 番目、`Quit` が 27 番目である。
- 狭い 80x24 では 28 項目を 14 行 2 列に分け、広い 120x40 では 1 列に並べる。
- 設定は `App.Model` の `theme` / `animationsEnabled` / `ui.animationSpeed` /
  `keymap` / `language` にだけ存在し、`Game` には保存されない。

### 27.5 テスト

- `tests/SettingsTest.idr`: 既定キー、コード解析・表示、再割り当て、
  重複検出、JSON の往復、未知 ID の無視、空配列の未割り当て、
  不正値・重複・未知テーマ・未知アニメーション速度の拒否、
  速度の往復と既定値、モデルの入力ルーティング、
  設定適用がゲームとリプレイを変えないこと、ファイル往復。
- `tests/SubsTest.idr`: キーマップ経由の移動・アイテム・方向、
  28 項目のパレット、設定・セーブ・ロード・リプレイ項目、グローバルキー。
- `tests/ViewTest.idr`: ヘルプとパレットのヒントが再割り当てに追従すること、
  ワイドヘルプが設定ファイルを示すこと。

### 27.6 既知の制約

- キー割り当てを対話的に編集する設定画面はない。ファイル編集と
  `Reload settings` で変更する。
- 設定の書き込みは直接 `writeFile` で、クラッシュ時の部分書き込みを防ぐ
  atomic rename は未実装。セーブ/オートセーブは `Persist.Save` の
  アトミック書き込みを使う。
- 不正な設定ファイルは既定値にフォールバックするため、どの行が悪いかを
  UI には表示しない。修正はファイルを直接確認する。
- マウス操作、テキスト入力、再生画面の操作はキーマップの対象外である。

## 28. ファイル永続化（2026-11-04、スライス 10-11）

戦績、リプレイ、セーブ/オートセーブ、セッションロックを追加した。
Core は JSON もファイル API も知らず、`Persist.*` が純粋な値と IO の境界を持つ。
詳細なスキーマと検証項目は `doc/persistence.md` を参照する。

### 28.1 モジュール

| モジュール | 役割 |
| --- | --- |
| `Persist.Paths` | `$XDG_DATA_HOME/lambda-rogue` または `$HOME/.local/share/lambda-rogue` の解決、`settings.json` / `scores.jsonl` / `replays/` / `save.json` / `autosave.json` / `session.lock` のパス、ディレクトリ作成、`joinPath`。 |
| `Persist.Json` | `Language.JSON` の型検証: `asString`, `asBool`, `asInt32`, `asBits32`, `field`, `asArray`, `arrayOf`, `hex64`。 |
| `Persist.Codec` | 座標、方向、状態、モンスター状態/種別、全アイテム種別、トラップ、メッセージ種別、タイル、死因、`GameOver` の安定 codec。 |
| `Persist.Score` | `lambda-rogue.score.v1` の JSON、JSON Lines の追記・読み込み。 |
| `Persist.Replay` | `lambda-rogue.replay.v1` のコマンド/replay JSON、保存・読み込み、ファイル名、一覧。 |
| `Persist.Save` | `lambda-rogue.save.v1` の `Game` 全体 codec、検証、アトミック書き込み、オートセーブ、削除、`session.lock`。 |
| `Persist.Settings` | 既存の `settings.json` IO。パス解決を `Persist.Paths` に委譲する。 |

Core 側の追加は `Core.Rng.seedFromHex`、`Core.Bitset.fromHex`、
`Core.Replay` の既存 API (`runReplay`, `gameDigest`, `replayMatches`,
`seedHex`) だけである。`Persist` は `Core` を import するが、逆方向の
依存はない。

### 28.2 戦績 `scores.jsonl`

```json
{"schema":"lambda-rogue.score.v1","seed":"0123456789abcdef","depth":7,"level":5,"exp":123,"gold":87,"turns":1240,"result":{"result":"dead","cause":{"kind":"monster","monster":"dragon"}}}
```

- 1 行 1 レコード。ファイルは古い順、`loadScores` は反転して新しい順を返す。
- `Score` の全フィールド（seed, depth, level, exp, gold, turns, result）を保存する。
- `result` は `gameOverToJSON` と同じ入れ子表現。死因は `monster` / `trap` /
  `starved` / `drained` / `other`。
- 空行、壊れた JSON、スキーマ不一致の行はスキップする。
- 追記は `appendScoreAt`、全体読み込みは `loadScoresAt`。パスを明示する
  `At` 版はテスト用でもある。

### 28.3 セーブ `lambda-rogue.save.v1`

トップレベルは `schema`, `kind`, `gameVersion`, `savedAt`, `game`。
`game` は `Core.Types.Game` の全フィールドを持つ。

```idris
record SaveFile where
  kind : SaveKind          -- Manual | Autosave
  savedAt : String
  game : Game

saveToJSON : SaveKind -> String -> Game -> JSON
saveFromJSON : JSON -> Maybe SaveFile
saveToText : SaveKind -> String -> Game -> String
saveFromText : String -> Maybe SaveFile
```

- `Save.SaveKind` は `Manual` / `Autosave`。`show` がそのまま `kind` になる。
- `Game` の seed は 16 文字、RNG 状態は 32 文字、`explored` / `visible` は
  448 文字の小文字 hex。
- `levels[].tiles` は 22 行 x 80 文字。タイルコードは
  `Persist.Codec.tileText` / `tileFromText` の 9 文字。
- アイテムの `location` は `pack` / `floor` / `monster`。識別知識は
  アイテムではなく `knownKinds` と `appearances` が持つ。
- `saveFromJSON` はスキーマ、`gameVersion`、`savedAt`、`Game` 全体を検証し、
  1 つでも不正なら `Nothing`。`loadSaveAt` は構文エラーも `Nothing` にする。
- `saveGameAt` / `saveGame` / `autoSave` は一時ファイル + `fsync` +
  `.bak` rename + `rename` + ディレクトリ `fsync` を使う。
- `loadSave` / `loadAutosave` / `deleteSave` / `deleteAutosave` が
  本番パスを解決する。`At` 版はテスト用。

### 28.4 セッションロック

```idris
acquireLockAt : String -> IO Bool
releaseLockAt : String -> IO ()
acquireSessionLock : IO Bool
releaseSessionLock : IO ()
```

- `session.lock` は `{ "pid": Int, "startedAt": String }`。
- 生存中の PID（`kill(pid, 0)` が成功、または `EPERM`）があれば `False`。
- `ESRCH` または壊れた JSON は stale とみなし、ロックを置き換えて `True`。
- `releaseLockAt` は自分が持つロックだけを削除する。
- `Main` はロック取得前にセーブを読まない。取得できなければメッセージを
  出して終了する。

### 28.5 App との接続

- `App.Update.persistRun` はゲーム終了へ遷移した瞬間に `appendScore` と
  `saveReplay` を `Perform` で実行し、`save.json` / `autosave.json` を削除する。
  失敗してもスコア画面とゲーム終了処理は継続する。
- 前進ターンが 10 の倍数になるたびに `autoSave` を `Perform` で実行する。
  表示専用コマンドはターンを進めないため、オートセーブも走らない。
- パレットの `Save and quit` は `saveGame Manual` の成功時だけ終了する。
  失敗時はゲームに留まる。
- パレットの `Load game` は `loadSave` を実行し、成功したら `game` を
  置き換え、リプレイを新しい seed で初期化し、`save.json` と
  `autosave.json` を削除する。読み込み失敗時は現在のランを維持する。
- `Main` は起動時に `settings` と `scores` を読み、`save.json`、
  `autosave.json` の順に再開する。読み込んだファイルは削除し、
  `"Resumed from save."` / `"Recovered from autosave."` を `SystemMsg`
  としてログ先頭に追加する。メッセージは `gameDigest` の対象外。
- `Main` はコマンドラインの `--seed <16 桁小文字 hex>` を
  `App.Startup.parseStartSeed` で解釈する。指定時はセーブを読まず、
  `save.json` / `autosave.json` を削除して `newGame seed` を開始する。
  未指定でセーブもない場合は、`System.Clock` の UTC ナノ秒と PID を
  `combineSeed` で混ぜた 64-bit seed を生成する。
- `App.Startup` は IO を持たない純粋な引数解析と seed 混合だけを担当し、
  `tests/StartupTest.idr` で `--seed` の受理・拒否を検証する。
- 正常終了時は `autosave.json` を削除し、最後に `releaseSessionLock` を呼ぶ。

### 28.6 テスト

`tests/PersistTest.idr` が次を検証する。

- `seedFromHex`、`Bitset.fromHex` の往復と不正入力。
- `Persist.Json` の型検証と `Persist.Codec` の全列挙・タイル・死因の往復。
- 勝利/死亡スコアの JSON 往復、JSON Lines の追記順、壊れた行のスキップ、
  欠損ファイル、未知スキーマ。
- 全コマンド種別のリプレイ JSON/テキスト往復、未知スキーマ、バージョン
  不一致、未知コマンド、不正方向、ファイル往復、壊れたファイルの拒否。
- セーブのスキーマ・種別・バージョン・`savedAt`、JSON/テキスト往復、
  不正な ID カウンタ、存在しない所持品、ファイル往復、`.bak`、
  壊れたファイル、欠損ファイル。
- セッションロックの取得、生存 PID の拒否、解放、死んだ PID と
  壊れたファイルの再利用。
- `verify.sh` はクリーンビルド、1160 件のテスト、PTY スモークを実行する。

### 28.7 既知の制約

- 手動セーブはパレットの `Save and quit` だけで、任意地点のセーブはない。
- 専用のロード画面はなく、起動時の自動再開とパレットの `Load game` だけ。
- 復旧確認ダイアログはない。`save.json` がなければ `autosave.json` を
  自動で採用する。
- `session.lock` は `hostname` / `bootId` を持たず、PID 再利用を厳密に
  判定しない。生存 PID は安全側で実行中とみなす。
- `settings.json`、`scores.jsonl`、リプレイファイルの書き込みは
  `writeFile` / `appendFile` で、atomic rename と `fsync` は未実装。
- リプレイの一覧・選択 UI とシークは M5 スライス 3 で実装済み。
  状態スナップショット型チェックポイントは未実装。
- 戦績の名前、殺害数、プレイ日時、並び替え UI は未実装。
- `gameDigest` は暗号学的ハッシュではない。改ざん検知ではなく再現性確認用。
- Clang 19 は rc2 の生成する `if ((a == b))` を
  `-Wparentheses-equality` として警告する。rc2 が `-Werror` を付けるため、
  `verify.sh` は Clang 検出時に `IDRIS2_CFLAGS` へ
  `-Wno-parentheses-equality` を追加する。

## 29. Rogue 5.4.4 忠実性監査（2026-11-07、スライス 12）

M4 の最後に、`Core` のデータ表・式・生成確率を 5.4.4 の公開データと照合した。
最終的な数値表は `doc/rogue-reference.md` を正とし、ここでは API との対応と
実装上の式だけをまとめる。

### 29.1 モンスター

- `MonsterSpec` は `glyph`, `name`, `level`, `attacks`, `ac`, `exp`,
  `minDepth`, `maxDepth`, `abilities` を持つ。
- `monsterSpec` の 26 種は 5.4.4 の公開モンスター表と一致する。
  `level` は表のレベル、`attacks` は `(個数, 面数)` のリスト、`ac` は表の AC、
  `exp` は HP ボーナスを除いた基礎経験値。
- `rollMonsterHp` は `roll level 8`。生成時とポリモーフ時の両方で使う。
- `monsterExpGain spec hp` は 5.4.4 の `exp_add` と同じ式:

  ```
  divisor = if level == 1 then 8 else 6
  multiplier = if level >= 10 then 20 else if level > 6 then 4 else 1
  exp + (hp / divisor) * multiplier
  ```

- `spawnPool depth` は深度帯に入る種類を返す。`spawnMonsters` は
  `monsterCount depth = min 12 (2 + depth/2)` 体を生成し、各種類を等確率で選ぶ。
- `monsterCarry` は 5.4.4 の `m_carry` 所持率を返す。`spawnMonsterPacks`
  は各モンスターに `uniform 100` を 1 回振り、成功時に通常物品 1 個を
  `CarriedBy` として生成する。0% の種類も乱数を消費する。
- 睡眠確率は 80%、`UsuallyAsleep` は 92%。
- `hasAbility` は能力の有無を返す。`Fast` は `monsterTurn` で 2 回行動、
  `Regenerate` は各モンスターの手番で HP +1。

### 29.2 戦闘と成長

- `playerArmorClass p = p.armor - p.ringArmor`。`p.armor` は防具の AC で、
  素手は 10。低いほど良い。
- `playerAttack p m g` の命中率:

  ```
  clamp 0 100 (5 + 5 * p.level + 5 * (monsterSpec m.kind).ac + p.ringAccuracy)
  ```

  1d100 を振り、出目が命中率以下なら命中。
- `strengthDamageBonus s` は 5.4.4 の筋力表:

  ```
  s <= 6       => s - 7
  7..15        => 0
  16..17       => 1
  18           => 2
  19..20       => 3
  21           => 4
  22..30       => 5
  31 以上      => 6
  ```

- プレイヤーのダメージは
  `max 1 (武器ダイス + strengthDamageBonus (effectiveStrength p)
          + p.weaponBonus + p.ringDamage)`。
- `monsterChance p m = clamp 0 100 (20 + 5 * (monsterSpec m.kind).level
  + 5 * playerArmorClass p)`。
- `monsterAttack` は `attacks` の各要素を独立に振り、合計ダメージを返す。
  `0d0` でも命中すれば特殊能力の契機になる。
- `expForNext` は 10, 20, 40, ..., 8,000,000 の累積表。`gainExperience` は
  経験値を消費せず、`level < 21` の間、必要経験値を満たすたびに
  `1d10` の最大 HP を得る。筋力は増えない。

### 29.3 アイテム生成

- `randomItemKind` の種別重み:

  | 種別 | 重み |
  | --- | --- |
  | potion | 26 |
  | scroll | 36 |
  | food | 16 |
  | weapon | 7 |
  | armor | 7 |
  | ring | 4 |
  | stick | 4 |

- `itemCount depth = min 8 (2 + depth/3)`、`goldPileCount depth =
  min 5 (1 + depth/5)` は M4 の密度値。公開表の値ではない。
- `randomItemKindWithFood noFood` は原本の `no_food > 3` を実装する。
  4 以上なら `uniform 100` の種別抽選を飛ばし、`uniform 10` で食料を
  決めてカウンタを 0 に戻す。通常抽選で食料を引いた場合も 0 に戻す。
  `randomItemKind` は `noFood = 0` のラッパーである。
- `spawnItemsWithFood` は床の通常物品と金塊を置き、更新後の
  `no_food` を返す。金塊はカウンタに影響しない。
- `enchantRoll kind`:
  - 武器: 1d100 が 0–9 で呪い、10–14 で祝福、それ以外は +0。
  - 防具: 0–19 で呪い、20–27 で祝福、それ以外は +0。
  - 呪いは `-(rnd(3)+1)`、祝福は `+(rnd(3)+1)`。範囲は -3..+3。
- `ringEnchantRoll`:
  - protection / add strength / dexterity / increase damage は
    `uniform 3` を 1 回振り、0 なら -1 かつ呪い、1 なら +1、2 なら +2。
  - aggravate monster / teleportation は +0 で常に呪い。
  - それ以外は +0、呪いなし、乱数消費なし。
- `wandCharges`:
  - `Wand WandLight` は `uniform 10` で 10–19。
  - それ以外の杖は `roll 1 5` で 3–7。
- `makeItem` は装備品のときだけ強化値・呪いを振り、指輪のときだけ
  `ringEnchantRoll` を振る。Gold の `count` は `1d10 * depth`（最低 1）。

### 29.4 アイテム効果

- 防具の AC は `armorValue a - enchant`。`recomputeArmor` が `p.armor` に入れる。
- 武器のダメージは `weaponDamage` のダイス + `enchant`。投擲は
  `weaponThrowDamage` を使う。
- 指輪の常時補正は `recomputeRings` が `ringArmor`, `ringDamage`,
  `ringAccuracy`, `ringStrength` に展開する。dexterity は `ringAccuracy` のみ。
- 回復の指輪は `survivalTurn` で 1 個につき HP +1。
- slow digestion は 1 個で空腹減少を 2 ターンに 1 回、2 個で 0 にする。
- テレポートの指輪は毎ターン `chance 2`（1/2）。
- ステルスの指輪は眠っているモンスターの起床半径を半分にする。
- sustain strength は毒・筋力ドライン・dart トラップを無効化する。
- maintain armor は錆を無効化する。`protected` の防具も錆びない。
- ポーション、巻物、杖、トラップの個別効果は
  `doc/rogue-reference.md` 10〜14 章の表を正とする。

### 29.5 既知の簡略化

次の項目は 5.4.4 と意図的に異なる。詳細と全リストは
`doc/rogue-reference.md` 17 章を参照する。

- 武器の命中・ダメージ強化値を単一の `enchant` で表す。
- 出現選択は深度帯の等確率で、原本の `level + rnd(10) - 6` ではない。
- 群れ生成、モンスターの所持率表、弓・投擲の遠距離攻撃は未実装。
- 巻物の scare / hold、confuse monster の対象・範囲が違う。
- 杖の drain life / cancellation の効果が違う。
- ポーションの幻覚・盲目・透明などの効果時間は短い固定式で、一部の効果は簡略化している。
- 飢餓は 0 以下で毎ターン 1 HP、失神と `-850` 死亡は未実装。
- 自然回復は `Game.quietTurns` による静穏ターン方式で、HP を失うと 0 に戻る。
- トラップの命中判定・セーヴ・矢の落下は未実装。浮遊中はトラップを発動しない。
- 秘密のドアは閉じたドアの 15% から生成する。原本の正確な生成確率は未確認である。
- ドラゴンの火炎反射は未実装。

### 29.6 テスト

- `tests/M4Test.idr` にモンスター表、装備の呪い・祝福、指輪の強化値、
  光の杖の充填数、dexterity の命中のみ反映、トラップ、ドラゴンの火炎、
  巻物・杖・ポーションの主要効果の回帰テストがある。
- `tests/CombatTest.idr` に命中式、筋力ダメージ、複数攻撃、経験値曲線、
  レベルアップのテストがある。
- `tests/CoreTest.idr` に生成の決定論、深度帯、モンスターの能力、
  アイテムの不変条件のテストがある。
- 正確なチェック数は `verify.sh` の実行結果と
  `doc/m1-measurements.md` を参照する。

## 30. M5 実装ノート（2026-11-09、スライス 1）

探索、searching の指輪、healing / extra healing、magic missile を
5.4.4 の式に合わせた。既存のリプレイ形式には `Search` を 1 種類追加しただけで、
他のコマンドの意味と乱数消費順は変えていない。

### 30.1 探索

```idris
public export
data Command
  = ...
  | Search
  | ...
```

- `Search` は 1 ターン消費し、プレイヤーは移動しない。
- 方向順（N, NE, E, SE, S, SW, W, NW）に隣接 8 マスの秘密のドアを判定し、
  その後 `Level.traps` の順に未発見トラップを判定する。
- 各対象で `uniform (2 + 盲目 2 + 幻覚 3)` を振り、0 なら発見する。
  通常 1/2、盲目 1/4、幻覚 1/5、盲目 + 幻覚 1/7。
- 秘密のドアは閉じたドアへ変わり「You found a secret door.」を出す。
  トラップは `revealed` を立て、種別ごとのメッセージを出す。幻覚中は
  「You found a trap.」と種別を伏せる。何も見つからなければ
  「You search but find nothing.」を出す。
- `searchDoors : Step -> (Step, Bool)` と
  `searchTraps : Step -> (Step, Bool)` が探索の乱数消費と発見をまとめ、
  `Search` と searching の指輪の両方が使う。

### 30.2 searching の指輪

- 移動が成立したターンだけ、`countRing RingSearching` の回数だけ
  `searchDoors` と `searchTraps` を無料で実行する。
- 待機、攻撃（移動先にモンスターがいる場合）、アイテム使用、階層移動では
  発動しない。
- 無料探索は追加のターンを消費せず、「何も見つからない」メッセージも出さない。
- 実行位置は `advanceTurn` の後、モンスター行動の前である。

### 30.3 回復ポーション

- healing: `roll p.level 4`。`hp + n > maxHp` なら `maxHp + 1` を新しい
  最大 HP とし、HP もその値にする。
- extra healing: `roll p.level 8`。`hp + n > maxHp` なら、まず
  `hp + n > maxHp + level + 1` のとき `maxHp + 2`、そうでなければ
  `maxHp + 1` を新しい最大 HP とし、HP をその値にする。
- どちらも超過しなければ HP だけを `min maxHp (hp + n)` まで回復する。

### 30.4 杖 of magic missile

- `WandMagicMissile` のダメージを 1d4 に変更した。ビームは最初に当たった
  モンスター 1 体だけに効く。

### 30.5 App と永続化

- `CommandId.Search`、既定キー `s`、パレット `Search for traps`
  （23 番目、全 25 項目）、ヘルプの wait / search / pick up 行を追加した。
- `Persist.Replay` は `{ "type": "Search" }` を読み書きする。
  `tests/PersistTest.idr` の往復対象コマンドに `Search` を加えた。

### 30.6 テスト

- `tests/M5Test.idr`（スライス 1 では 15 チェック、現在は 23 チェック）:
  探索のターン消費、隣接トラップの発見、遠距離トラップの非発見、空探索の
  メッセージ、searching の指輪の移動時発動、待機時の非発動、
  healing / extra healing のダイスと最大 HP 増加、magic missile の 1d4。
  スライス 4 で秘密のドアの遮蔽、探索による発見、開扉、遠距離の非発見、
  searching の指輪による発見を追加した。
- `tests/M3Test.idr` の extra healing は、固定の全回復ではなく
  「HP が増え、最大 HP を超えない」ことを検証する形に更新した。
- `tests/SettingsTest.idr`、`tests/SubsTest.idr`、`tests/ViewTest.idr` に
  `s` キー、パレット 25 項目、ヘルプの search 表示を追加した。
- 全体は 795 チェックから始まり、スライス 4 時点で 1003、スライス 5 で 1010、スライス 6 で 1013、スライス 7 で 1023、スライス 8 で 1027、スライス 9 で 1031、スライス 10 で 1035、スライス 11 で 1036、スライス 12 で 1037、スライス 13 で 1042、スライス 14 で 1046、スライス 15 で 1049、スライス 16 で 1053、スライス 17 で 1056、スライス 18 で 1061、スライス 19 で 1065、スライス 20 で 1071、スライス 21 で 1074、スライス 22 で 1077、スライス 23 で 1088、スライス 24 で 1094、スライス 25 で 1101、スライス 26 で 1102、スライス 27 で 1105、スライス 28 で 1106、スライス 29 で 1109、スライス 30 で 1112、スライス 31 で 1114、スライス 32 で 1119、スライス 33 で 1123、スライス 34 で 1125、スライス 35 で 1128、スライス 36 で 1131、スライス 37 で 1139、スライス 38 で 1145、スライス 39 で 1152、スライス 40 で 1157、スライス 41 で 1160、現在は 1160 チェック。

## 31. M5 スライス 2 実装ノート（2026-11-10、メッセージカタログ）

### 31.1 Core のメッセージ

- ゲームログの文字列生成を `Core.Game` から `Core.Message.Msg` に移した。
  `Core.Game` は `mkMessage turn kind msg` だけを呼び、英語文を直接組み立てない。
- `Msg` は型付きの引数を持ち、`msgKey` は `damage`, `kill-monster`,
  `descend-level` などの安定キー、`msgArgs` は表示用の文字列引数を返す。
- `Message` は `turn`, `kind`, `key`, `args`, `text` を持つ。`text` は
  M5 以前と同一の正規英語文で、旧セーブ・未知キーのフォールバックになる。
- `msgEn` の出力はカタログ導入前の文字列と一致させ、既存テストと
  セーブの可読性を保つ。
- `sampleMessages` は全構築子の代表値を並べたテスト・文書用の一覧である。

### 31.2 App のカタログ

- `Language = English | Japanese`、既定は `English`。`languageId` は
  `en` / `ja`。
- `renderMessage : Language -> Message -> String` は英語では常に `text`、
  日本語では `key` に対応するテンプレートへ `args` を順に埋める。
  `key = ""` または未知キーは `text` を返す。
- `TextKey` と `uiText` / `uiTextArgs` はヘルプ、パレット、ステータス、
  プロンプト、戦績、共有、端末・起動エラーの文言を同じ方式で描画する。
- `allTextKeys` は UI キーの全一覧で、`CatalogTest` が英語・日本語の
  非空性と件数を検証する。
- パレットの英語ラベルは設定・テスト用の正規識別子として残し、
  `paletteEntriesForLang` が表示時だけ日本語ラベルへ置き換える。

### 31.3 言語の選択と不変条件

- `settings.json` の `language` は既定 `en`。未知の ID は `en` に落とす。
- `--lang en|ja` はその起動だけ設定を上書きし、不明値・欠落はエラーにする。
  エラー文も `--lang` で選ばれた言語で表示する。
- 言語は `Model.language` にだけ存在し、`Game`, `Replay`, `Command`,
  `gameDigest`, セーブのゲーム部分には入らない。
- 旧セーブの `key` / `args` 欠落は空として読み込み、`text` を表示する。
  リプレイは言語を持たないため、`--lang` を変えても同じコマンド列で再生できる。

### 31.4 テスト

- `CatalogTest`（32 チェック）: メッセージキーの重複、全構築子の日本語
  テンプレート網羅、英語 `msgEn` との一致、引数順、旧メッセージ・未知キーの
  フォールバック、UI キーの網羅、パレットラベルの翻訳、パレットの言語切替、
  言語切替後の `gameDigest` とリプレイ不変。
- `SettingsTest`: `language` の JSON 往復、欠落時の英語、未知 ID の英語
  フォールバック、非文字列の拒否、`ApplySettings` 後の状態不変。
- `StartupTest`: `--lang en|ja`、`--seed` との併用、欠落・不正値、
  日本語エラー文。
- `PersistTest`: メッセージ `key` / `args` の往復、旧セーブの英語
  フォールバック、不正な `args` の拒否。
- `ViewTest`: 日本語のヘルプ、パレット、スコア、共有、持ち物、ログ、
  ステータス、ホバー、端末警告の実描画。スコアの死因列と、英語・日本語で
  同じ端末セル幅になる列幅も検証する。
- 全体は 814 チェックから 897 チェックへ増えた。

## 32. M5 スライス 4 実装ノート（2026-11-12、秘密のドア）

### 32.1 生成

- `Core.Dungeon.concealDoors` が `Door Closed` のタイルを行優先で列挙し、
  各ドアについて `chance 15` を振り、真なら `Door Secret` に置き換える。
  乱数は他の生成処理がすべて終わった後に消費するため、部屋・階段・
  モンスター・アイテム・トラップの配置は従来と同じ順序で決まる。
- `Door Secret` は `walkable = False`、`openable = False`、
  `Fov.transparent = False` である。プレイヤーにもモンスターにも壁と同じ
  振る舞いをする。
- 同じ seed と同じコマンド列からは同じ秘密のドア配置になる。スライス 4
  以前のビルドとは生成乱数の消費順が異なるため、同じ seed でも生成される
  ダンジョンは以前と一致しない。

### 32.2 探索と開扉

- `searchDoors` は方向順（N, NE, E, SE, S, SW, W, NW）に隣接セルを見て、
  `Door Secret` があれば `uniform (2 + 盲目 2 + 幻覚 3)` を振る。0 なら
  `Door Closed` に変え、`FoundSecretDoor` メッセージを出す。
- `searchTraps` は従来どおり `Level.traps` の順に未発見トラップを判定する。
  `searchArea` はドア探索の後にトラップ探索を行い、どちらか発見すれば
  「何も見つからない」メッセージを出さない。
- searching の指輪の `ringSearch` も `searchDoors` と `searchTraps` を
  この順で呼ぶ。無料探索である点と、追加ターンを消費しない点は変わらない。
- 秘密のドアを発見した後は通常の閉じたドアであり、歩くと `openDoor` が
  `Door Open` にする。未発見のまま歩くと「There is a wall there.」で
  ターンを消費しない。

### 32.3 表示と永続化

- `UI.MapView.tileGlyph (Door Secret) = '#'`、`tileStyleIn` は `RockRole`
  を使う。`tileName` は「wall」を返すため、ホバー表示でも秘密が漏れない。
- セーブのタイルコードは既存の `s`（`Persist.Codec`）を使う。リプレイは
  引き続き seed と意味的コマンド列だけを保存する。

### 32.4 テスト

- `DungeonTest`: 生成レベルに秘密のドアが存在すること、秘密のドアが
  歩行不可であること。到達性の検査では秘密のドアを「探索後に通過可能」と
  みなす。
- `M5Test`: 未発見のドアが移動を遮ること、探索で `Door Closed` に変わること、
  メッセージ、ターン消費、発見後の開扉、遠距離の非発見、
  searching の指輪による発見。
- `MapViewTest`: 秘密のドアが壁の字形とスタイルで描画されること。
- 全体は 991 チェックから 1003 チェックへ増えた。

## 33. M5 スライス 5 実装ノート（2026-11-12、Orc の強欲 AI）

### 33.1 行動

- `hasAbility Greedy m.kind` を持つモンスターが `Awake` または `Chasing`
  のとき、`greedyAct` を使う。`Asleep` と `Fleeing` は従来の処理のまま。
- 隣接するプレイヤーがいれば `monsterStrike` を優先する。金塊の上に
  立っていても、隣接プレイヤーへの攻撃が先である。
- それ以外では `nearestVisibleGold` が現在の階の `Gold` のうち
  `canSee` を満たす座標を集め、チェビシェフ距離が最小のものを選ぶ。
  同距離は `Game.items` の早い順で、乱数は消費しない。
- 金塊の座標にいれば `pickUpGold` で `location` を `CarriedBy m.id` に
  変える。1 ターンを消費し、そのターンは移動しない。
- 金塊へ向かう途中は `stepToward` と `moveMonsterTo` を使うため、閉じた
  ドアを開けて進む既存の挙動を共有する。金塊が見えない、または到達経路が
  見つからない場合は `rangedOrChase` に戻る。
- 混乱中は金塊を探さず `randomMove` を使う。

### 33.2 死亡時

- 拾った金塊は既存の `CarriedBy` として `Game.items` に残る。
- `dropCarriedBy` が死亡したモンスターの所持品を死亡位置の `OnFloor` に
  戻すため、Orc を倒すと金塊がその場に落ちる。専用のドロップ処理は
  追加していない。

### 33.3 テスト

- `M5Test` に、可視の金塊へ向かうこと、拾得して床から消えること、
  足元の金塊を拾うこと、隣接プレイヤーへの攻撃を優先すること、
  非強欲モンスターが拾わないこと、死亡時に落とすことを追加した。
- 全体は 1003 チェックから 1010 チェックへ増えた。

## 34. M5 スライス 6 実装ノート（2026-11-12、杖の light）

### 34.1 効果

- `revealRoom` は `roomAt` でプレイヤーの座標を含む `Room` を探し、その
  矩形の外周 1 マスを含む範囲を `Level.explored` に加える。
- 部屋にいない場合（通路など）は `explored` を変更しない。ターン消費と
  充填消費は通常の杖の処理に従う。
- 乱数は消費しない。`revealMap` は魔法の地図の全階表示専用として残す。
- メッセージ `WandFloodsLight` の英語・日本語を部屋向けに変更した。
  メッセージキー `wand-floods-light` は変えない。

### 34.2 テスト

- `M4Test` の light の期待値を、全 1760 マスから現在の部屋の 220 マスへ
  更新した。
- `M5Test` に、現在の部屋が `explored` になること、別の部屋と通路が
  暗いままであること、メッセージが部屋に触れることを追加した。
- 全体は 1010 チェックから 1013 チェックへ増えた。

## 35. M5 スライス 7 実装ノート（2026-11-13、Xeroc の物体擬態）

### 35.1 状態と擬態先

- `StatusKind` に `Mimicking` を追加した。`MimicObject` を持つ Xeroc は
  生成時に `MkStatus Mimicking 1` を持つ。`tickMonsterStatuses` はこの状態を
  減らさず、解除は明示的な処理だけで行う。
- `mimicKindFor` はモンスター ID の `mod 8` から、食料・ポーション・巻物・
  杖・指輪・武器・防具・金の 8 種類を選ぶ。`mimicKinds` が対応表である。
- 擬態先を乱数にしないため、レベル生成の乱数消費とリプレイの決定論は
  変わらない。

### 35.2 表示と解除

- `MapView` は可視の擬態中モンスターを、擬態先の `itemGlyph` と
  `itemStyle` で描画する。ホバー名は `mimicDisplayName` が返す未識別の
  アイテム名で、「xeroc」を出さない。
- `App.View.monsterLine` は擬態中のモンスターを一覧から除外する。
  起床時は `MonsterWoke` イベントだけを出し、`MonsterWakesUp` メッセージを
  出さない。
- `monsterTurn` はモンスターの移動・プレイヤー HP の変化・新規メッセージの
  いずれかが起きたとき `revealMimic` を適用する。眠ったまま何もしない
  Xeroc は擬態を保つ。
- プレイヤーの攻撃（命中・外れ）、`damageMonster`、`WandPolymorph` も
  `revealMimic` を通す。杖のビームで傷ついた時点で正体が分かる。

### 35.3 永続化と検証

- `Mimicking` は既存の `status` 配列の `kind` 文字列として保存される。
  セーブ形式のバージョンは変えない。古いセーブに擬態状態がなければ、
  Xeroc は最初から正体が見えている状態で復元される。
- `validLevels` は `Mimicking` を持つモンスターが `MimicObject` を持つことを
  検証し、`validPlayer` はプレイヤーがこの状態を持たないことを検証する。
- `Codec.statusKindFromText` と `PersistTest` の全状態一覧に `Mimicking` を
  追加した。

### 35.4 テスト

- `M5Test` に、移動・睡眠・攻撃・起床・被攻撃・生成時擬態の 7 チェックを
  追加した。`MapViewTest` に擬態中の字形、名前、解除後の `X` の 3 チェックを
  追加した。
- 全体は 1013 チェックから 1023 チェックへ増えた。

## 36. M5 スライス 8 実装ノート（2026-11-13、静穏ターン自然回復）

### 36.1 状態

- `Game` に `quietTurns : Turn` を追加した。意味は「HP を失わずに消費した
  連続ターン数」で、0 以上を検証する。
- `survivalTurn` は毒・飢餓を適用した後の HP をターン前と比べ、減っていれば
  `quietTurns` を 0 にする。減っていなければ 1 増やす。
- `naturalHeal` は絶対ターン番号ではなく `quietTurns` を受け取る。
  レベル 1–8 は `healInterval`、レベル 9 以上は 3 ターンで判定し、
  回復したら計数を 0 に戻す。満タンなら判定もロールも行わない。
- 回復の指輪は別枠で毎ターン HP を回復するが、`quietTurns` は進めたままに
  する。毒・飢餓のダメージは計数を 0 に戻す。

### 36.2 永続化

- セーブの `game` に `"quietTurns"` を追加した。古いセーブにこの
  フィールドがなければ 0 として復元するため、`lambda-rogue.save.v1` の
  まま読み込める。
- 負の `quietTurns` は `validGame` が拒否する。

### 36.3 テスト

- `M5Test` に、レベル 1 で 17 ターンでは回復しないこと、18 ターンで
  1 HP 回復して計数が 0 に戻ること、毒ダメージで計数が 0 に戻ること、
  満タンでは乱数を消費しないことの 4 チェックを追加した。
- 全体は 1023 チェックから 1027 チェックへ増えた。

## 37. M5 スライス 9 実装ノート（2026-11-13、remove curse の防具限定）

### 37.1 挙動

- `applyScroll ScrollRemoveCurse` は `player.worn` の防具 ID だけを見る。
  そのアイテムがパックにあり呪われていれば `cursed := False` にし、
  `recomputeArmor` を通す。
- 防具を着ていない場合や、防具が呪われていない場合も、巻物の消費と
  1 ターンの消費は通常どおり行う。メッセージは `SurgeOfRelief` のまま。
- 所持しているだけの武器・指輪・防具、装備中の武器や指輪の呪いは解除しない。

### 37.2 テスト

- `M4Test` の remove curse は、呪われた防具を `Wear` してから読む形に
  更新した。
- `M5Test` に、装備防具の解除、所持指輪の呪い維持、巻物の消費、
  防具なしで所持品の呪いが残ることの 4 チェックを追加した。
- 全体は 1027 チェックから 1031 チェックへ増えた。

## 38. M5 スライス 10 実装ノート（2026-11-13、浮遊中のトラップ無効）

### 38.1 挙動

- `playerMove` は移動後に常に `triggerTrap` を呼ぶ。`triggerTrap` が浮遊を
  判定し、浮遊中はトラップを発動せず、発見済みにもしない。移動先に
  未発見トラップがあれば `FloatOverTrap` を表示する。
- 浮遊していない場合のトラップ処理は従来どおり。

### 38.2 テスト

- `M5Test` に、浮遊中のダメージなし、トラップが未発見のままであること、
  浮遊メッセージ、浮遊なしでは同じトラップが発動して発見済みになることの
  4 チェックを追加した。
- 全体は 1031 チェックから 1035 チェックへ増えた。

## 39. M5 スライス 11 実装ノート（2026-11-13、aggravate の起床）

### 39.1 挙動

- `aggravateMonster` はモンスターの `state` を `Chasing` にし、
  `Sleeping` 状態を除去する。`Mimicking` など他の状態はそのまま残す。
- aggravate monsters の巻物と aggravate monster の指輪は、どちらも
  この関数を全モンスターに適用する。
- 眠っていたモンスターは次のモンスターターンから追跡を始める。

### 39.2 テスト

- `M4Test` の巻物と指輪の aggravate テストを、`Sleeping` 状態を持つ
  モンスターで検証する形に更新した。
- テスト数は 1035 から 1036 へ増えた（パレット順序のテストを含む）。

## 40. M5 スライス 12 実装ノート（2026-11-14、sleep の巻物）

### 40.1 挙動

- `applyScroll ScrollSleep` は読み手に `Sleeping 6` を付与し、
  `FallAsleep` を表示する。睡眠トラップと同じ持続で、実効 5 行動。
- モンスターの状態・位置・睡眠状態には触れない。
- `MonstersSleep` メッセージは古いセーブのログを読めるように残しているが、
  新しいゲームでは生成しない。

### 40.2 テスト

- `M4Test` を、読み手が `Sleeping` になり「You fall asleep.」が出ること、
  モンスターが睡眠状態にならないことの 2 チェックに更新した。
- 全体は 1036 チェックから 1037 チェックへ増えた。

## 41. M5 スライス 13 実装ノート（2026-11-14、飢餓の失神）

### 41.1 挙動

- `StatusKind` に `Fainted` を追加した。失神中は `Sleeping` / `Paralyzed`
  と同じくコマンドを受け付けず、ターンだけ消費する。
- 空腹度が 0 以下のとき、失神していなければ毎ターン `chance 20` で
  `Fainted 2` を付与する。実効 1 行動を失い、失効時に「You come to.」を出す。
- 飢餓による毎ターン 1 HP の減少を削除した。空腹度が `starvingDeathAt`
  (`-850`) 以下になった時点で `Starved` にする。
- セーブの `hunger` 検証は `> -850` に緩め、飢餓中のオートセーブを
  拒否しないようにした。

### 41.2 テスト

- `M3Test` に、失神の発生と頻度、失神ターンの消費、`-850` 死亡、
  HP が減らないことのテストを追加した。
- `PersistTest` に、負の空腹度のセーブ往復と `-850` の拒否を追加した。
- 全体は 1037 チェックから 1042 チェックへ増えた。

## 42. M5 スライス 14 実装ノート（2026-11-14、浮遊中の行動制限）

### 42.1 挙動

- `pickUp` は最初に `Levitated` を判定し、浮遊中なら
  `CannotPickUpLevitating` を表示してターンを消費しない。
- `stairsAction` も最初に `Levitated` を判定し、浮遊中なら
  `CannotUseStairsLevitating` を表示してターンを消費しない。
  上り・下りの両方が対象で、階段の上にいなくても同じメッセージになる。
- 浮遊中のトラップ無効は従来どおり `triggerTrap` が担当する。

### 42.2 テスト

- `M5Test` に、浮遊中の拾い上げ拒否とメッセージ、浮遊中の階段拒否、
  浮遊なしでは同じ階段が使えることの 4 チェックを追加した。
- 全体は 1042 チェックから 1046 チェックへ増えた。

## 43. M5 スライス 15 実装ノート（2026-11-15、hold monster の射程と解除）

### 43.1 挙動

- `applyScroll ScrollHoldMonster` は、プレイヤーとのチェビシェフ距離が
  2 以下のモンスターにだけ `Held 10` を付与する。距離 3 以上は変更しない。
- `attackMonster` は攻撃対象の `Held` を除外した状態リストを先に作り、
  命中・外れのどちらでもそのリストでモンスターを更新する。
  `ConfuseNext` による `Confused` は従来どおり命中時だけ追加する。
- 攻撃の命中判定・ダメージ・経験値は従来どおりで、拘束の解除だけを加える。

### 43.2 テスト

- `M4Test` に、距離 2 のモンスターが拘束されること、距離 5 のモンスターが
  拘束されないこと、拘束中のモンスターへの攻撃が命中・外れの両方で
  `Held` を外すことを追加した。命中と外れは複数シードの攻撃結果から
  両方を選び、どちらの経路も検証する。
- 全体は 1046 チェックから 1049 チェックへ増えた。

## 44. M5 スライス 16 実装ノート（2026-11-15、slime mold）

### 44.1 挙動

- `FoodKind` は `FoodRation` と `SlimeMold` の 2 種。`itemName` は
  `show` を通して `"food ration"` / `"slime mold"` を返す。
- `randomItemKind` は食料枠を引いたとき、追加で 1d10 を振り、0 なら
  `SlimeMold`、それ以外は `FoodRation` を返す。食料以外の抽選経路は
  従来と同じ乱数消費である。
- `eat` はどちらの食料も空腹度を `hungerMax` 回復する。メッセージだけを
  `EatRation` / `EatSlimeMold` に分ける。
- `Persist.Codec.allItemKinds` に slime mold を加え、セーブの `kind` 文字列
  から復元できるようにした。スキーマ番号は変更しない。

### 44.2 テスト

- `M3Test` に slime mold の栄養回復とメッセージの 2 チェックを追加した。
- `M4Test` に、生成結果に food ration と slime mold の両方が現れること、
  売値が 2 であることの 2 チェックを追加した。
- `CatalogTest` のメッセージ数は 145 になった。
- 全体は 1049 チェックから 1053 チェックへ増えた。

## 45. M5 スライス 17 実装ノート（2026-11-15、回復ポーションの状態解除）

### 45.1 挙動

- `cureSenses` は `Blinded` / `Confused` / `Hallucinating` を状態リストから
  除く。`healing` と `extra healing` は HP 計算の後にこれを適用する。
- `cureBlindness` は `Blinded` だけを除く。`see invisible` は
  `SeeInvisible` を付与した後にこれを適用する。
- いずれも追加メッセージは出さず、既存の「Feel better.」系メッセージに
  状態解除を同居させる。

### 45.2 テスト

- `M3Test` に、healing が盲目・混乱・幻覚を解除すること、extra healing が
  盲目を解除すること、see invisible が盲目を解除して SeeInvisible を
  付与することの 3 チェックを追加した。
- 全体は 1053 チェックから 1056 チェックへ増えた。

## 46. M5 スライス 18 実装ノート（2026-11-17、魔法の地図とポーション時間）

### 46.1 挙動

- `revealMap` は `explored` を全マスにしたうえで、`Level.traps` の
  `revealed` をすべて `True` にする。トラップ種別のメッセージは出さない。
- `spread` は `Game.idr` の内部関数で、`n - n/20` に
  `uniform (n/10 + 1)` を足した `Int32` を返す。`spread 850` は
  808–892、`spread 30` は 29–31 になる。
- `PotionHallucination` / `PotionBlindness` / `PotionSeeInvisible` は
  `spread 850`、`PotionLevitation` は `spread 30` を使う。
  `PotionConfusion` / `PotionHasteSelf` / 感知系は従来の短い式のまま。
- 乱数消費は 1 回で、既存の `roll` と同様に状態・ターン・ダイジェストへ
  決定的に反映される。

### 46.2 テスト

- `M3Test` に、幻覚・盲目・透明が 807–892、浮遊が 28–31 に収まることの
  4 チェックを追加した（消費ターン分の 1 を許容）。
- `M4Test` に、magic mapping が未発見トラップも `revealed` にすることの
  1 チェックを追加した。
- 全体は 1056 チェックから 1061 チェックへ増えた。

## 47. M5 スライス 19 実装ノート（2026-11-17、魔法感知の対象）

### 47.1 挙動

- `Item.isMagicalItem : Item -> Bool` を追加した。ポーション・巻物・
  指輪・杖・アミュレットは常に `True`。武器は `enchant /= 0` または
  `cursed`、防具はそれに `protected` を加えた条件で `True`。食料と金は
  `False` になる。
- `PotionMagicDetection` は床の物品のうち `isMagicalItem` が `True` の
  ものだけを `explored` に加える。対象外の物品があっても乱数消費や
  メッセージは変わらない。
- 判定は表示用の `explored` だけを変え、`Item` や `Game` の他の状態は
  変更しない。セーブ・リプレイのスキーマ変更はない。

### 47.2 テスト

- `M4Test` の `potionDetectionTests` に 4 チェックを追加した。魔法物品
  4 種の表示、強化値 +1 の武器と -1 の防具の表示、食料・金・強化値 0 の
  武器の非表示、アミュレットの表示を固定する。
- 全体は 1061 チェックから 1065 チェックへ増えた。

## 48. M5 スライス 20 実装ノート（2026-11-17、対象のない感知ポーション）

### 48.1 挙動

- `detectionHasTarget : PotionKind -> Game -> Bool` は、`magic detection`
  なら同階の床に `isMagicalItem` の物品があるか、`monster detection`
  なら現在の階にモンスターがいるかを返す。それ以外のポーションは常に
  `True` になる。
- `quaff` はこの判定が `True` のときだけ `addKnown` で種別を識別する。
  対象がない場合はポーションを消費して 1 ターン使い、種別は未識別の
  ままにする。
- `applyPotion` の `PotionMagicDetection` / `PotionDetectMonsters` は、
  対象がないとき `StrangeFeeling`（「You have a strange feeling for a
  moment, then it passes.」）だけを表示し、感知状態を付与しない。
- どちらの経路でも `roll 1 8` は 1 回実行する。対象の有無で乱数消費数が
  変わらないため、リプレイの決定性は保たれる。
- `Message` に `StrangeFeeling` を追加し、英語・日本語カタログに
  `strange-feeling` を登録した。

### 48.2 テスト

- `M4Test` に、魔法感知が対象を見つけたときの識別、対象なしの
  メッセージ、未識別・状態なし、怪物感知の同様の 3 系統を追加した。
- `CatalogTest` のメッセージ数は 145 から 146 になった。
- 全体は 1065 チェックから 1071 チェックへ増えた。

## 49. M5 スライス 21 実装ノート（2026-11-17、魔法感知の表示）

### 49.1 挙動

- `MapView.cellForWith` の「探索済みだが視界外」の分岐で、物品があれば
  `DetectMagic` かつ `isMagicalItem` のとき物品記号と `DetectedItemRole`
  を返す。`DetectFood` の食料判定と同じ分岐にまとめた。
- 視界内の物品表示、未探索マスの非表示、通常の地形の暗い表示は変えない。
- 魔法感知は対象のマスを `explored` にするため、状態が続く間は視界外でも
  記号が見える。状態が切れると記号は消え、探索済み地形だけが残る。

### 49.2 テスト

- `MapViewTest` に、魔法感知なしではポーションが地形として隠れること、
  魔法感知ありでは `!` と `detectedItemStyle` で見えること、同じ状態でも
  普通の武器は隠れることの 3 チェックを追加した。
- 全体は 1071 チェックから 1074 チェックへ増えた。

## 50. テストの `Model` 構築（2026-11-17、型検査メモリの削減）

### 50.1 背景

- `tests/ViewTest.idr` は `Model` を `MkModel c g 80 24 False ...` の
  25 引数で 18 回直書きしていた。`tests/PerfTest.idr` に 8 回、
  `tests/SubsTest.idr` に 3 回、同じ形があった。
- rc2 バックエンド（Chez）はこの形の型検査でメモリを急増させる。
  クリーンな `--typecheck lambda-rogue-tests.ipkg` のピークは
  3,947 MiB、208 秒だった。`tests/ViewTest.idr` だけで 4,038 MiB、
  249 秒を使っていた。
- 同じ時点でアプリ本体の型検査ピークは 389 MiB であり、テストの
  書き方が原因だと切り分けられた。スライス 19〜21 の変更前
  （`df332bd`）でも 3,934 MiB だったため、直近の変更由来ではない。

### 50.2 方針

- テストの `Model` は `initModel c g` を土台にし、既定と違うフィールド
  だけをレコード更新で指定する。既定値は `App.Model.initModel` が
  一箇所で持つ。
- レコード更新の対象が関数適用のときは、型を注釈した束縛
  （`m : Model`）を置く。そうしないと「Can't infer type for this
  record update」になる。
- `emptyReplay` の種だけが既定と違う場合は、`initModel` が `g.seed` を
  使うことに注意する。フィクスチャの `Game` がその種を持っていれば
  （`newGame 42` など）そのまま一致する。

### 50.3 結果

- テストのクリーンビルド（型検査 + codegen + C コンパイル）のピークは
  1,062 MiB、251 秒。型検査だけなら 911 MiB、110 秒。
- C コンパイラ（clang 19、`-O2`）のピークは 572 MiB で、ボトルネックは
  コンパイラ本体だった。
- チェック数は 1074 のまま変わらない。

## 51. M5 スライス 22 実装ノート（2026-11-17、未探索マスの怪物感知）

### 51.1 挙動

- `MapView.monsterCellIn : Theme -> Bool -> Monster -> Cell` を追加し、
  視界内と感知時の怪物セル生成を一本化した。ミミックは変装した物品記号と
  `ItemRole`、それ以外は `monsterGlyph` と `MonsterRole`（感知時は
  `DetectedMonsterRole`）を使う。
- `cellForWith` の未探索マスの分岐は、`DetectMonsters` があり、かつ
  `monsterHidden` でないモンスターがいるときだけ怪物セルを返す。
  それ以外は従来どおり `Nothing` で、地形も描かない。
- `monsterHidden` の規則（透明・隣接・see invisible）は視界内と同じ
  なので、感知で透明モンスターの位置は漏れない。
- `describeCell` は未探索マスに `Nothing` を返すため、感知した怪物の
  ホバー説明から名前は漏れない。

### 51.2 テスト

- `MapViewTest` に、未探索マスのモンスターが状態なしでは描かれないこと、
  `DetectMonsters` でケストレルが `K` と `detectedMonsterStyle` で
  見えること、透明な幻影は状態があっても描かれないことの 3 チェックを
  追加した。
- 全体は 1074 チェックから 1077 チェックへ増えた。

## 52. M5 スライス 23 実装ノート（2026-11-17、勝利時の売却スコア）

### 52.1 挙動

- `Core.Types` に `potionGoldValue` / `scrollGoldValue` / `ringGoldValue` /
  `wandGoldValue` を追加した。値は 5.4.4 の `pot_info` / `scr_info` /
  `ring_info` / `ws_info` の `oi_worth` である。武器は `weaponValue`、
  防具は `armorGoldValue` を使う。
- `Core.Item.itemWorth` は 1 個分の売却額と、売却後の既知種別を返す。
  武器は `weaponValue * (3 * (2 * enchant) + count)`、防具は
  `armorGoldValue + (9 - ac) * 100 + 10 * (armorValue - ac)`（`ac` は
  `armorValue - enchant`）、食料は `2 * count`、アミュレットは 1000、
  杖は `wandGoldValue + 20 * charges`、指輪は種類ごとの価格に
  protection / add strength / dexterity / increase damage の強化値を
  加える。負の値は 0 にする。
- 未識別のポーション・巻物・指輪・杖は、`knownKinds` に種類がない間は
  半額にする。1 個売るとその種類を既知にし、同じ種類の次の個体は
  全額になる。原本が `total_winner()` のループで `oi_know` を立てる
  順序と同じである。
- `itemsWorth` は `packItems` の順に合計する。`packWorth` は
  `knownKinds` を初期値にする。`finalScore` は死亡時には
  `player.gold`、勝利時には `player.gold + packWorth` を返す。
- `App.Model.scoreOf` は `player.gold` ではなく `finalScore` を
  スコアの `gold` フィールドに記録する。永続化スキーマは v1 のまま。
- 計算は純粋で乱数を消費しない。ターン、`gameDigest`、リプレイ、
  セーブには影響しない。

### 52.2 テスト

- `M5Test` に、死亡時は所持金のみ、食料とアミュレット、武器の強化値、
  矢の束、呪われた武器の 0 切り上げ、強化防具、未識別ポーションの
  半額と既知化、指輪の強化値、杖の充填数の 10 チェックを追加した。
- `ReplayTest` に、勝利した `scoreOf` が手持ち品の売却額を含むことの
  1 チェックを追加した。
- 全体は 1077 チェックから 1088 チェックへ増えた。

## 53. M5 スライス 24 実装ノート（2026-11-18、食料の栄養と味）

### 53.1 挙動

- `Core.Survival` に `stomachSize = 2000`、`foodNutritionBase = 1100`、
  `foodNutritionSpread = 400` を追加した。`hungerMax = 1300` は開始値と
  消化の基準に残る。
- `Core.Game.eat` は、空腹度が負なら 0 にしてから
  `1100 + uniform 400` を加え、`stomachSize` で頭打ちにする。
  栄養の乱数は食料の種類にかかわらず 1 回だけ消費する。
- `FoodRation` は続けて `uniform 100` を振り、71 以上（29%）なら
  `gainExperience` で経験値 +1。レベル閾値に届けば 1d10 の最大 HP 増加と
  「Welcome to level N!」が続く。`SlimeMold` は追加の乱数を消費せず、
  経験値も与えない。
- 味のメッセージを `EatFood` / `EatFoodTrippy` / `EatFoodAwful` /
  `EatFoodAwfulTrippy` に分けた。幻覚中は `choose_str()` と同じく
  trippy 版を使う。`EatSlimeMold` は
  「my, that was a yummy slime-mold」。
- 乱数消費は「栄養 → 味」の順で、原本 `eat()` と同じである。ターン消費は
  従来どおり食べた後に 1 回。

### 53.2 テスト

- `M3Test` の食料テストを 11 チェックに更新した。栄養のロール、
  2000 の上限、food ration の経験値 +1 と味、幻覚時のメッセージ、
  slime mold が経験値を与えないことを確認する。
- 味の分岐は、テスト内で決定的に探索したシードを使う。ゲームの乱数列は
  固定のまま。
- 全体は 1088 チェックから 1094 チェックへ増えた。

## 54. M5 スライス 25 実装ノート（2026-11-18、arrow / dart トラップ）

### 54.1 挙動

- `Core.Combat.swing atLevel opArm wplus` を追加した。1d20 を振り、
  `res + wplus >= (20 - atLevel) - opArm` なら命中。トラップは
  `wplus = 1`、`opArm = p.armor - p.ringArmor` を渡す。
- `Core.Game.arrowTrap` は `swing(level - 1, AC, 1)`。外れると
  `Weapon Arrow` を `OnFloor depth pos` に追加し、`nextItemId` を 1 進める。
  命中すると 1d6 を振って `trapDamageWith ArrowTrap` を適用する。
- `Core.Game.dartTrap` は `swing(level + 1, AC, 1)`。外れると何も残さない。
  命中すると 1d4 を振り、生きていれば
  `1d20 >= 14 - level div 2` の毒セーヴを行う。失敗で筋力 -1。
  `RingSustainStrength` を装備しているときはセーヴの乱数を消費しない。
- `Core.Game.trapDamageWith` は、命中判定で消費済みの乱数を受けて
  ダメージだけを適用する。`trapDamage` はロールしてからこれを呼ぶ。
- 乱数の消費順は「命中判定 → ダメージ → 毒セーヴ」。外れと
  sustain strength では後続のロールを消費しない。
- メッセージ `ArrowShot` / `ArrowShootsPast` / `DartHits` /
  `DartWhizzesBy` を追加し、日本語カタログも更新した。死亡時の文面は
  既存の `Die` 共通形式で、死因は `KilledByTrap`。

### 54.2 テスト

- `CoreTest` に arrow の外れ 3 チェック（無傷・矢の落下・新 ID）を追加した。
- `M4Test` に dart の命中・外れ・毒失敗・セーヴ成功の 4 チェックを追加した。
- テスト用シードは固定値。`M5Test` の浮遊トラップは命中するシードに
  変更しただけで、ゲーム本体の乱数列には触れていない。
- 全体は 1094 チェックから 1101 チェックへ増えた。

## 55. M5 スライス 26 実装ノート（2026-11-18、mysterious トラップ）

### 55.1 挙動

- `Core.Types` に `rainbowColors`（27 色、原本 `rainbow[]` の順）と
  `rainbowColor : Bits64 -> String` を追加した。色は英語のトークンで、
  表示層が翻訳する。
- `Core.Game.mysteriousTrap` は `uniform 11` で 0–10 を選び、
  11 種のメッセージに対応させる。色付きの 4 種（1・4・6・10）だけ
  続けて `uniform 27` を振る。それ以外は追加の乱数を消費しない。
- `Msg` に 11 個の mysterious 用コンストラクタを追加した。固定文面の
  `StrangeNoise` は使わなくなったため削除した。
- 日本語カタログは 4 つの色引数を `colorNameJa` で翻訳する。
- 原本は `rainbow[rnd(cNCOLORS)]` と 1 始まりで添字を引くため、
  最大値で配列外を参照する。lambda-rogue は 0 始まりで 27 色から選び、
  乱数の消費数は原本と同じに保つ。

### 55.2 テスト

- `M4Test` の mysterious チェックを 2 件に更新した。シード 0 で
  「You suddenly feel very thirsty.」、シード 1 で色付きの
  「The light in here suddenly seems violet.」を確認する。
- `CatalogTest` のメッセージ数は 163 になった。固定の strange-noise を
  削除し、11 個を追加したため、全体では +10 である。
- 全体は 1101 チェックから 1102 チェックへ増えた。

## 56. M5 スライス 27 実装ノート（2026-11-18、0 始まりの乱数）

### 56.1 挙動

- 原本 `rnd(range)` は `0 .. range-1` を返す（`range = 0` なら乱数を
  消費せず 0）。`roll(n, sides)` は `rnd(sides)+1` を n 回足す。
- `Combat.swing` は `uniform 20`（0–19）を使う。`(20 - at_lvl) - op_arm`
  との比較はそのままなので、矢・吹き矢トラップの命中率が原本の式になる。
- `Game.spread n` は `n - n div 20 + uniform (n div 10)` に直した。
  `n div 10 = 0` のとき `uniform 0` は乱数を消費しない。
- 混乱は `spread 20`（19–20）、モンスター感知は `spread 20`（19–20）、
  加速は `uniform 4 + 4`（4–7）にした。幻覚・盲目・透明は
  `spread 850`（808–892）、浮遊は `spread 30`（29–31）になる。
- ターン終了時に状態が 1 減るため、飲んだ直後に観測できる残りターンは
  それぞれ 1 少ない。これは既存の睡眠・浮遊と同じ扱いである。

### 56.2 テスト

- `M3Test` に混乱・加速・モンスター感知の持続チェックを追加した。
- 幻覚・盲目・透明の範囲を 807–891、浮遊を 28–30 に更新した
  （`spread` の値から飲んだターンの 1 を引いた範囲）。
- `M4Test` / `CoreTest` のトラップ用シードは変更なしで通った。
  0 始まりになっても、固定シードでの命中・外れの判定は同じである。
- 全体は 1102 チェックから 1105 チェックへ増えた。

## 57. M5 スライス 28 実装ノート（2026-11-19、モンスターの所持品）

### 57.1 挙動

- `Monster.monsterCarry : MonsterKind -> Nat` は 5.4.4 の `m_carry`
  所持率（%）を返す。centaur 15、dragon 100、griffin 20、
  jabberwock 70、medusa 40、nymph 100、orc 15、troll 50、
  vampire 20、xeroc 30、yeti 30、それ以外 0。
- `Dungeon.spawnOnePack` は各モンスターについて `uniform 100` を 1 回振り、
  `carryRoll < monsterCarry kind` なら `randomItemKind` と `makeItem` で
  通常物品を 1 個作る。0% の種類も乱数を消費し、金塊・アミュレットは
  抽選に含まれない。
- 生成した物品は `{ location := CarriedBy m.id }` にして
  `spawnMonsterPacks` がモンスター順に集める。生成順はモンスター、
  所持品、深度 26 のアミュレット、床アイテムの順である。
- 所持品はマップ・ピッキング・床の一覧には現れない。モンスターが死ぬと
  既存の `dropCarriedBy` が最後の位置へ落とす。
- `CarriedBy` は既存のセーブ形式で保存でき、復元時にモンスター ID の
  実在を検証するため、スキーマ変更はない。

### 57.2 テスト

- `DungeonTest.itemsValid` は床アイテムの数と所持品を分けて検査する。
  床アイテムは従来どおり `itemCount + goldPileCount + アミュレット`、
  所持品は実在するモンスター ID・個数 1・非金塊・非アミュレットを確認する。
- 「モンスターが物品を持つ階がある」チェックを追加した。
- 全体は 1105 チェックから 1106 チェックへ増えた。

## 58. M5 スライス 29 実装ノート（2026-11-19、加速の重ね飲み）

### 58.1 挙動

- 加速中に `PotionHasteSelf` を飲むと `uniform 8`（0–7）を 1 回振り、
  `Hasted` を外して `Fainted` を付ける。原本 `add_haste()` の
  「加速を解除して `no_command += rnd(8)`」に対応する。
- `Fainted` は付与したターンの終了時に 1 減る。そのため `k > 0` のとき
  は `Fainted (k + 1)` を付け、以降 `k` ターンの行動を飛ばす。
  `k = 0` のときは状態を付けず、加速解除だけを行う。状態を付けると
  同じターンに期限切れの「意識を取り戻した」が出てしまうため。
- メッセージは `FaintFromExhaustion` を追加し、英語は
  「You faint from exhaustion.」、日本語は「疲労で気を失った。」。
  重ね飲みでは「moving much faster」を出さない。
- 加速でないときの挙動は従来どおり `uniform 4 + 4`（4–7）である。

### 58.2 テスト

- `M3Test` に、加速中の重ね飲みで `Hasted` が外れること、
  「You faint from exhaustion.」が出ること、`Fainted` が 7 ターン以下で
  あることの 3 チェックを追加した。
- `CatalogTest` のメッセージ数は 163 から 164 になった。
- 全体は 1106 チェックから 1109 チェックへ増えた。

## 59. M5 スライス 30 実装ノート（2026-11-19、食料優先生成）

### 59.1 挙動

- `Game.noFood : Int32` を追加した。新階を生成するたびに 1 増やし、
  食料を生成すると 0 に戻す。初期値は 0。
- `Item.randomItemKindWithFood noFood` は、`noFood > 3` のとき原本
  `new_thing()` と同じく種別の `uniform 100` を振らず、`uniform 10`
  だけで `SlimeMold` / `FoodRation` を決める。どちらの経路でも食料なら
  返すカウンタは 0、それ以外は入力をそのまま返す。
- `randomItemKind` は `noFood = 0` のラッパーとして残した。既存の
  抽選分布テストと固定フィクスチャはそのまま使える。
- `Dungeon.spawnMonsterPacks` は新階で増やす前のカウンタを使い、
  `spawnItemsWithFood` は `+1` した後のカウンタを使う。原本は
  `do_rooms()`（モンスターと所持品）の後に `no_food++` して
  `put_things()`（床の物品）を呼ぶためである。
- `generateLevelWithFood` が実際の生成経路で、既存の `generateLevel` は
  `noFood = 0` のラッパーである。`Game` の下降処理は `g.noFood` を渡し、
  `GeneratedLevel.noFood` を次の状態へ保存する。
- セーブ JSON の `game.noFood` は任意フィールドで、省略時は 0。
  負値は `validGame` が拒否する。`gameDigest` の正規状態文字列にも
  `noFood` を含めた。

### 59.2 テスト

- `M4Test` に、`noFood = 4` で食料が強制されカウンタが 0 になること、
  `noFood = 3` でも通常抽選で食料を引けば 0 になることの 2 チェックを
  追加した。食料を引くシードはテスト内で決定的に探索する。
- `DungeonTest` に、`generateLevelWithFood 1 1 1 4` が食料を含み、
  `noFood` が 0 になることの 1 チェックを追加した。
- 全体は 1109 チェックから 1112 チェックへ増えた。

## 60. M5 スライス 31 実装ノート（2026-11-20、トラップ密度）

### 60.1 挙動

- `Dungeon.spawnTraps` はまず `uniform 10` を振り、`depth` 未満なら
  トラップのある階とする。旧実装の `randInt 0 3` を置き換えた。
- 個数は `uniform (depth / 4) + 1` とし、10 で頭打ちにする。
  0 始まりの `uniform 10` は 0–9 なので、10 階以降は必ず 1 個以上。
  26 階は `uniform 6 + 1` で 1–6 個になる。
- 種類は `trapKinds` から、位置は残りの歩行可能マスから一様に選ぶ。
  この部分と乱数消費順は変えていない。
- トラップはアイテム・モンスター・階段の位置を避ける既存の候補生成を
  そのまま使う。

### 60.2 テスト

- `DungeonTest.trapsValid` の上限を 3 から 10 にした。
- 「10 階以降は必ずトラップがある」と「個数は `1 + depth/4` 以下」の
  2 チェックを追加した。浅い階は `rnd(10) < depth` の確率でしか
  トラップを持たないため、この 2 チェックは 10 階以降だけを見る。
- 全体は 1112 チェックから 1114 チェックへ増えた。

## 61. M5 スライス 32 実装ノート（2026-11-21、venus flytrap）

### 61.1 挙動

- `Game.vfHits : Int32` を追加した。初期値は 0。
- venus flytrap の攻撃は通常の `monsterAttack` で命中判定だけを行い、
  ダメージは専用の `flytrapStrike` が決める。
  - 命中: ダメージは `vfHits + 1`。その後 `vfHits` を 1 増やす。
  - 外れ: ダメージは現在の `vfHits`。`vfHits` は変えない。
  - 初回命中は 1 ダメージ、2 回目は 2 ダメージになる。
- `vfHits` は全個体で共有する。原本はモンスター雛形のダメージ文字列を
  書き換えるため、別の flytrap の攻撃にも強化が引き継がれる。
- flytrap の死亡時は `vfHits` を 0 に戻し、プレイヤーの `Held` を
  すべて取り除く。原本 `killed()` の `vf_hit = 0` と `ISHELD` 解除に
  対応する。`Held` は熊トラップなどと共有のため、原本と同じく
  発生源を問わず解除する。
- セーブ JSON の `game.vfHits` は任意フィールドで、省略時は 0。
  負値は `validGame` が拒否する。`gameDigest` の正規状態文字列にも
  含めた。

### 61.2 テスト

- `M4Test` に次の 5 チェックを追加した。
  - 初回命中で 1 ダメージ、`vfHits = 1`。
  - 2 回目の命中で 2 ダメージ、`vfHits = 2`。
  - 外れても現在の `vfHits` ダメージを与え、カウンタを変えない。
  - flytrap の死亡で `vfHits` が 0 に戻る。
  - flytrap の死亡で `Held` が解除される。
- 外れのチェックは armor 0 のプレイヤーと決定的なシード列を使い、
  外れかつ `vfHits = 3` のダメージが入る手を探索する。
- 全体は 1114 チェックから 1119 チェックへ増えた。

## 62. M5 スライス 33 実装ノート（2026-11-21、drain life）

### 62.1 挙動

- `WandDrainLife` はビームではなく、プレイヤーのいる部屋全体に効く。
  `roomAt` で部屋を求め、`roomContains` で同じ部屋のモンスターを集める。
  部屋にいないときは隣接モンスターだけを対象にする。
- 対象がいればプレイヤー HP を `hp / 2`（整数除算）にし、
  `(hp / 2) / 対象数`（整数除算）を各モンスターに与える。
  ダメージが 0 なら各モンスターには何も起きない。
- 対象がいなければ HP を変えず `DrainLifeTingling` を出す。
- プレイヤー HP が 1 以下なら `zap` の段階で `TooWeakToDrain` を出し、
  充填を減らさずにターンだけ消費する。原本 `do_zap()` の早期 return に
  対応する。
- 乱数は消費しない。旧実装の 2d6 ロールと自己回復を削除した。

### 62.2 テスト

- `M4Test` の drain life チェックを、HP 半減・均等ダメージに更新した。
- 2 体のモンスターに半分が等分されること、HP 1 で充填が残ること、
  対象なしで HP が変わらず tingling が出ることの 3 チェックを追加した。
- `CatalogTest` のメッセージ数は 164 から 166 になった。
- 全体は 1119 チェックから 1123 チェックへ増えた。

## 63. M5 スライス 34 実装ノート（2026-11-22、炎の反射）

### 63.1 挙動

- `WandFire` はビーム上の最初のモンスターを調べ、ドラゴンなら
  `FlameBouncesOffDragon` を出して終了する。モンスターの HP は変えず、
  ビームはその位置で止まる。
- 反射時は `zapDamage` を呼ばないため、`6d6` のダメージロールも
  乱数消費も行わない。
- ドラゴン以外では従来どおり `6d6` ダメージを与える。
- メッセージは英語「The flame bounces off the dragon.」、日本語
  「炎はドラゴンに跳ね返された。」。

### 63.2 テスト

- `M4Test` に、ドラゴンへ火の杖を撃つと反射メッセージが出ること、
  ドラゴンの HP が 100 のままであることの 2 チェックを追加した。
- `CatalogTest` のメッセージ数は 166 から 167 になった。
- 全体は 1123 チェックから 1125 チェックへ増えた。

## 64. M5 スライス 35 実装ノート（2026-11-22、魔法感知）

### 64.1 挙動

- `PotionMagicDetection` は `1d8` を振らず、`DetectMagic` を付与値 2
  （実効 1 行動）で付ける。乱数は消費しない。
- 感知対象は同階の床にある魔法物品と、同階のモンスターが所持する
  魔法物品である。`monsterCarriesMagic` が `CarriedBy` の物品を調べる。
- 床の魔法物品は従来どおり探索済みマスに物品記号で表示する。
- モンスターの所持品は、`DetectMagic` の間だけそのモンスターの位置に
  `$` と `detectedItemStyle` で表示する。可視・記憶済み・未探索の
  どのマスでも同じように上書きする。
- 対象が 1 つもなければ従来どおり `StrangeFeeling` を出し、種別は
  識別しない。対象があれば `SenseMagic` を出して識別する。
- `detectionHasTarget` を `applyPotion` より前に移し、床と所持品の
  両方を見るようにした。

### 64.2 テスト

- `M4Test` に、モンスターが持つ魔法物品だけで識別・感知状態が付くこと、
  そのクオッフで RNG が変化しないことの 2 チェックを追加した。
- `MapViewTest` に、魔法物品を持つモンスターが `$` で表示されることの
  1 チェックを追加した。
- 全体は 1125 チェックから 1128 チェックへ増えた。

## 65. M5 スライス 36 実装ノート（2026-11-23、モンスター感知）

### 65.1 挙動

- `PotionDetectMonsters` は `spread 20` を呼ばず、固定 20 ターンの
  `DetectMonsters` を付ける。乱数は消費しない。表示上の残りは付与直後
  19 になる。
- 感知対象がないときのメッセージは、幻覚中なら `StrangeFeeling`、
  そうでなければ `NormalFeeling` になる。`noTargetFeeling` が
  `choose_str("strange", "normal")` に対応する。
- 対象がない場合は従来どおり種別を識別せず、感知状態も付かない。
- メッセージは英語「You have a normal feeling for a moment, then it
  passes.」、日本語「しばらく普通の感じがしたが、すぐに消えた。」。

### 65.2 テスト

- `M4Test` に、モンスター感知が乱数を消費しないこと、20 ターン
  （残り 19）続くこと、幻覚中の魔法感知が strange feeling になることの
  3 チェックを追加した。
- `CatalogTest` のメッセージ数は 167 から 168 になった。
- 全体は 1128 チェックから 1131 チェックへ増えた。

## 66. M5 スライス 37 実装ノート（2026-11-23、cancellation）

### 66.1 挙動

- `StatusKind` にモンスター専用の `Cancelled` を追加した。
  `tickMonsterStatuses` は `Mimicking` と同様にこれを減らさない。
- `WandCancellation` は対象の `Mimicking` を取り除き、`Cancelled 1` を
  1 つだけ付ける。既存の `Held` などの状態異常と `MonsterState` は
  変更しない。乱数は消費しない。
- `Cancelled` のモンスターは `monsterAbilityOnHit` の特殊攻撃
  （凍結、ホールド、ドレイン、錆、窃盗）を行わない。通常攻撃は行う。
- ドラゴンの火炎放射は `rangedOrChase` で `isCancelled` を確認して抑止する。
- `MapView.monsterHidden` は `Cancelled` のモンスターを透明として扱わない。
  xeroc は擬態状態が外れるため、本来の `X` で表示される。
- メッセージは従来どおり「The <monster> looks ordinary again.」を出す。
- セーブの `status` 配列は `kind` 文字列で保存するため、`cancelled` を
  `Codec.statusKindFromText` と `PersistTest` の一覧に追加した。

### 66.2 テスト

- `M4Test` の cancellation テストを、状態を残す仕様に更新した。
  擬態解除、キャンセル済みドラゴンの火炎なし、キャンセル済み氷
  モンスターの凍結なしを追加した。
- `MapViewTest` に、透明モンスターの非表示とキャンセル後の表示の
  2 チェックを追加した。
- 全体は 1131 チェックから 1139 チェックへ増えた。

## 67. M5 スライス 38 実装ノート（2026-11-24、食料感知）

### 67.1 挙動

- `ScrollFoodDetection` は乱数を消費しない。`floorFoodCells` が同階の
  床にある `Food` だけを集める。`CarriedBy` の食料は対象外。
- 食料があれば、そのマスを探索済みにして `DetectFood 2`（実効 1 行動）
  を付け、`SenseFood`「Your nose tingles and you smell food.」を出す。
  このとき `Scroll ScrollFoodDetection` を識別する。
- 食料がなければ `NoseTingles`「Your nose tingles.」だけを出し、
  種別は未識別のまま、状態も付けない。
- `read` は食料感知の巻物だけ、効果前の `addKnown` を行わない。
  識別は `applyScroll` が対象を見つけたときに行う。

### 67.2 テスト

- `M4Test` の食料感知テストを、乱数非消費、実効 1 行動、識別、
  食料マスの探索済み、対象なしの tingles、未識別、状態なしの
  7 チェックに置き換えた。
- `CatalogTest` のメッセージ数は 168 から 169 になった。
- 全体は 1139 チェックから 1145 チェックへ増えた。

## 68. M5 スライス 39 実装ノート（2026-11-24、ビーム杖の魔法セーヴ）

### 68.1 挙動

- `Combat.monsterMagicSave` は原本の `save_throw(VS_MAGIC, tp)` を再現する。
  `need = 14 + 3 - level / 2`（端数切り捨て）に対し `roll(1, 20) >= need`
  で成功する。乱数は常に d20 を 1 回だけ消費する。
- モンスターのレベルは種族の基本レベル。原本はアミュレット階より深い分で
  `s_lvl` を加算するが、lambda-rogue は深度補正を持たない。
- `lightning` / `fire` / `cold` / `magic missile` はダメージを振る前に
  セーヴを行う。成功時はダメージを振らず、`lightning` / `fire` / `cold`
  は `BoltWhizzesPast` / `FlameWhizzesPast` / `IceWhizzesPast` を、
  `magic missile` は `MagicMissileVanishes` を出す。
- `lightning` / `fire` / `cold` のセーヴ成功は対象を `Chasing` にし、
  `Held` 状態を除く（原本 `runto` の `ISRUN` と `ISHELD` 解除）。
  `magic missile` は状態を変えない。
- `fire` のドラゴン反射はセーヴ失敗時だけ判定する。成功時は
  「The flame whizzes past the dragon.」でダメージなし。
- ビームは最初のモンスターで止まるため、原本のようにセーヴ成功した
  対象を通過して奥のモンスターへ進む挙動は未実装。
- メッセージを 4 種追加した。`CatalogTest` のメッセージ数は 169 から
  173 になった。

### 68.2 テスト

- `M4Test` に、セーヴ失敗時の各ビームのダメージ、ドラゴンの反射、
  ドラゴンのセーヴ成功、`lightning` のセーヴ成功とかすめ表示、
  追跡状態、d20 1 回だけの消費、`magic missile` の消滅の 7 チェックを
  追加した。決定論的なシードは `failedMagicSaveSeed` と
  `successfulMagicSaveSeed` で求める。
- `M5Test` の「magic missile deals 1d4 damage」は、セーヴ失敗シードを
  使うように更新した。
- 全体は 1145 チェックから 1152 チェックへ増えた。

## 69. M5 スライス 40 実装ノート（2026-11-25、scare monster の床オーラ）

### 69.1 挙動

- `ScrollScareMonster` を読むと `ManiacalLaughter`
  「You hear maniacal laughter in the distance.」を出すだけ。モンスターの
  状態は変えず、乱数も消費しない。巻物は通常どおり消費・識別する。
- `scareScrollAt` は同階の床にある `Scroll ScrollScareMonster` を探す。
  `free` がこのマスを拒否するため、追跡・逃走・ランダム移動のどの
  モンスターも踏み込まない。
- `createMonsterCells` を公開し、`create monster` の配置候補からも
  scare monster のマスを除外する。通常の巻物は除外しない。
- 原本の「拾い直すと塵になる」処理は `ISFOUND` に依存するため未実装。
  `Item` に取得済みフラグを追加する必要がある。

### 69.2 テスト

- `M4Test` の scare monster テストを、読み取りが笑い声だけで状態を
  変えないこと、床の巻物が追跡モンスターの侵入を妨げること、通常の
  巻物は妨げないこと、生成候補の除外と通常巻物の許可の 6 チェックに
  置き換えた。
- `CatalogTest` のメッセージ数は 173 のまま（`MonstersFlee` を
  `ManiacalLaughter` に置き換えたため）。
- 全体は 1152 チェックから 1157 チェックへ増えた。

## 70. M5 スライス 41 実装ノート（2026-11-26、create monster の隣接配置）

### 70.1 挙動

- `createMonsterCells` はプレイヤーの隣接 8 マスだけを、上から下・
  左から右の順で返す。`monsterPassable`（床・通路・階段・開いた扉・
  閉じた扉）で、モンスターのいるマスと scare monster のマスを除く。
- `chooseCreateCell` は原本 `S_CREATE` と同じリザーバーサンプリング。
  i 番目の候補で `uniform i` を振り、0 なら選択を置き換える。
  候補が空なら乱数を消費しない。
- `createMonsterNear` は配置選択、種別、HP の順に乱数を消費する。
  候補がなければ `FaintCry`
  「You hear a faint cry of anguish in the distance.」を出す。
- `monsterPassable` を `createMonsterCells` より前に移し、
  `ScrollFizzles` を `FaintCry` に置き換えた。

### 70.2 テスト

- `M4Test` に、生成モンスターがプレイヤーに隣接していること、隣接 8 マス
  すべてが埋まっているときに `FaintCry` を出して生成しないことの
  3 チェックを追加した。
- `CatalogTest` のメッセージ数は 173 のまま（`ScrollFizzles` を
  `FaintCry` に置き換えたため）。
- 全体は 1157 チェックから 1160 チェックへ増えた。
