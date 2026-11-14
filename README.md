# AltermaticMenuPreview

A UE4SS Lua mod for Palworld that shows [Altermatic](https://www.nexusmods.com/palworld/mods/1626)
material swaps on the **Pal status screen's 3D preview** (party menu and Palbox).

Altermatic only alters Pals that spawn in the world, so packs such as
[Shining Luckies](https://www.nexusmods.com/palworld/mods/2044) show their textures in the world
but the status screen still shows the stock Pal. This mod fills that gap. It does not hook into
Altermatic: it reads the same SwapJSON files and applies them to the preview itself.

> **Disclaimer: this mod was vibe coded.** It was written with an AI assistant and
> shaped by trial and error in game, not by someone who knows Palworld's or UE4SS's
> internals. It works on my setup (Steam on Linux/Proton, the official mod loader,
> Shining Luckies), but it hasn't been reviewed or tested much beyond that. Use it
> at your own risk, and keep backups of your saves.

## Requirements

- Palworld with UE4SS (the Workshop "UE4SS Experimental (Palworld)" used by the official mod loader)
- Altermatic + UniPalUI, and at least one Altermatic pack installed in `Pal/Content/Paks/~mods/SwapJSON`
- An up-to-date `SwapJSON/_LoadList.json` (run `__Create_Load_List__.bat`, or the `.sh` port on Linux)

## Install

Copy this folder to `Palworld/Mods/NativeMods/UE4SS/Mods/AltermaticMenuPreview/`
(the `Scripts/main.lua` and the empty `enabled.txt`). UE4SS starts it automatically.

## What it does

When a status screen finishes building its 3D preview
(`WBP_PalStatus_C:OnCompletedCaptureActorSetup`), the mod:

1. Reads the shown Pal from the widget (`LastHoveredPalHandle`): CharacterID, Lucky flag,
   gender, skin and passives.
2. Picks the matching `SkelMeshSwap` entry from the packs in `_LoadList.json`, like Altermatic:
   - `CharacterID` must match exactly (`SheepBall`, `BOSS_SheepBall`, ...).
   - `IsRarePal`, `Gender`, `SkinName` and `ReqTrait` are honoured when set.
   - The entry with the most matching conditions wins; ties go to load-list order.
3. Puts each `MatReplace` material on its slot index of the preview model
   (`BP_PalMonsterCaptureSet_C.SkeletalMesh`) and forces its textures to full resolution.
4. Restores the stock materials when the preview shows a Pal with no matching entry.

## Limitations

- **Material swaps only.** Entries that replace the whole model (a different `SkelMeshPath`)
  are skipped and logged.
- **Variants may differ from the world.** Altermatic picks randomly among several matching
  entries per Pal (and Shift+O re-rolls); this mod always picks the most specific one.
- **Official skins.** A Pal wearing a skin only gets an entry made for that skin
  (`SkinName`, or a `CharacterID` equal to the skin name); otherwise it keeps the skin,
  matching Altermatic's behaviour in the world.
- `PrefTrait` and `MorphTarget` are ignored. Portrait icons are not changed.

## Troubleshooting

Everything is logged to `Mods/NativeMods/UE4SS/UE4SS.log` with the prefix `[AltermaticMenuPreview]`:
how many entries were loaded, which Pal each status screen showed, and how many slots were set.

Notes on this UE4SS build that shaped the code:

- Hook callbacks on blueprint functions run after the function body; the separate post-hook
  callback never fires. Work is deferred with `ExecuteInGameThread` (a blocking load inside the
  hook can deadlock the game thread).
- UE4SS `LoadAsset` only sees the base game's asset registry. Assets from mod paks are loaded
  through `KismetSystemLibrary` soft-object paths and `LoadAsset_Blocking`.
- The preview is rendered off-screen by a scene capture, so streamed textures stay at low
  resolution unless forced resident.

## Credits

- Altermatic by michaelpstanich; SwapJSON format and the Lucky-Pal material packs belong to their authors.
- Shining Luckies by Apollocy22.
