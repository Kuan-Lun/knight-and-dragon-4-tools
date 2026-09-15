# Remaining auto-level visual states

The battle detector identifies the page using only the fixed graphical shapes of the bottom skip and all-auto controls. Both footer anchors require correlation and absolute luminance agreement of at least 0.94. The skill control is excluded because its brightness changes during combat. Normal pause and retreat controls are optional, separate evidence: a missing pause match preserves battle-page identity but cannot establish a running battle; a retreat candidate requires both normal pause and retreat matches. A still image does not prove that all-auto is enabled or that combat is advancing. Combat progress and stalled recovery still require chronological evidence and bounded waiting.

`manifest.json` records 17 visually inspected native screenshots, their SHA-256 hashes and dimensions: nine battle layouts and eight modal/nonbattle negatives. Native 406×890 and 812×1780 frames are preserved without alterations. The 2× source is copied as `battle-native-2x.png`; other originals are referenced by repository path. Test resources reuse existing PNGs wherever available. `battle-templates.json` records generator sources and sample hashes.

The detector ignores the battle header, loot count, talisman name, enemies and skill-control brightness. There are no loot-label templates or count-dependent registration alternatives. Fixed footer positions are shared by both native resolutions.

Version 0.4.26 trims the upper edge of both footer regions from y=0.867 to 0.870,
preserving their lower edges. The September 13 incident showed that the old regions
included three changing border rows at native 812×1780 resolution. The glyphs below
those rows were unchanged. `battle-templates.json` was regenerated from the same two
original source images; the incident captures are independent regression inputs in
`Tests/MirrorProbeCoreTests/Fixtures/battle-footer-variant-sequence.json`, not template
sources. The 0.94 threshold and registration tolerance remain unchanged.

| Visual family | Strong existing originals | Reusable graphical features |
| --- | --- | --- |
| Battle with different enemies and HP values | `active-battle-control-grid.png`, `active-battle-low-retreat-grid.png`, `visual-battle-low-auto.png` | Skip and all-auto footer glyphs; optional normal-pause/retreat controls |
| One-line and talisman/two-line battle headers | `visual-battle-native-2x.png`, `visual-battle-progress-before.png`, `visual-battle-progress-after.png` | Header differences are ignored; the same two footer glyphs identify the page |
| Battle activity | `visual-battle-progress-before.png` → `visual-battle-progress-after.png` | Chronological party-card and combat-log pixel changes; a single frame is insufficient |
| Battle intro, encounter and event prompts | `Images/battle-intro-one-button.png`, `Images/battle-event-one-button.png`, `Images/battle-prompt-one-button-alt.png` | Existing central wide-button geometry; exact dialog text and scene title vary |
| Defeat and retreat prompts | `Images/defeat-one-button.png`, `Images/retreat-two-buttons.png` | Active modal button geometry; stacked/dimmed background controls must not authorize battle input |
| Loot collection and recruitment prompts | `Images/loot-two-buttons.png`, `Images/adventurer-two-buttons.png`, `Images/adventurer-two-buttons-colin.png` | Existing one/two-row wide-button geometry; variable adventurer names/stats excluded |
| Returned-party notification on map | `Images/returned-party-manual-stop.png` | Wide single close button over a map, not a battle frame |

The paths in the table are relative to `Tests/MirrorProbeCoreTests/Fixtures` unless otherwise noted. Recruitment examples were visually inspected during the inventory and are covered by the existing modal suite; they are not duplicated in this battle manifest. The monster-defeated event pair in `DevelopmentFixtures/PendingRegressions/battle-event-monster-defeated-20260904/` supplies another native one-button event with a different narrative.

The historical `natural-defeat-all-zero.png` name is misleading: its first party card visibly retains `3684/14K` HP while the other five show zero. It is retained as `visual-battle-five-zero-hp.png` and labeled only as battle-layout evidence. It must not become an all-zero defeat template. Likewise, the `pause-low-confidence` fixture displays the normal pause button; it is not a user-paused battle.

No verified native screenshot was found in this bounded survey for an explicitly user-paused battle, inventory-full dialog, mirror disconnect/lock screen, or a positively distinguished enabled/disabled all-auto toggle pair. Native 2× modal examples are also missing. Missing either footer glyph fails closed. Missing optional pause or retreat evidence keeps the battle identity but never grants retreat. Tests additionally obscure each required footer anchor, independently obscure optional controls, change skill/header brightness in an in-memory RGBA buffer, and validate malformed visual-evidence rejection; these are synthetic negative tests, not native capture claims.

Templates and regression captures overlap. Passing this corpus establishes regression coverage and preserves original source evidence; it is not an independent measurement of accuracy across all game screens.
