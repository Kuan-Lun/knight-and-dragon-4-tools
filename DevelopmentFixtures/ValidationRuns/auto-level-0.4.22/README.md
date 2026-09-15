# Auto-level 0.4.22: low-confidence intact result titles

Two user-started runs on 2026-09-11 Asia/Taipei exposed the same OCR failure.

- `auto-level-20260911-051405.MSkXSb`: zero completed cycles or posted inputs.
  All nine observations read the intact `任務完成！` title at confidence 0.5.
  The 0.6 marker threshold yielded unknown until the 15-second grace expired.
- `auto-level-20260911-051602.awbevq`: one completed cycle and five posted inputs.
  Capture 19 is the EXP result; input 5 successfully advances to loot in capture
  20. All subsequent loot observations have the same low-confidence title.
  Without a recognized loot identity, the pending EXP input cannot receive its
  semantic acknowledgement and eventually reports `actionDidNotAdvance`.

Both retained loot screens visibly have an intact title, trusted loot header,
repeat row, and selection stamp. OCR processing is under half a second in the
source reports; these incidents do not show stale-observation expiry. The
second run's before/after pictures establish that its continuation click worked.

Offline Vision revision 3 experiments on the original images gave title
confidence 1.0 when reading the fixed top-left region x=0.25, y=0.07, width=0.5,
height=0.08. Runtime now tries that region once on the same immutable image,
only for a complete selected-result scaffold with a unique exact title in
the 0.5..<0.6 range. Focused OCR must independently meet the existing 0.6
threshold, agree on the text and location, and pass full reclassification with
all other original observations intact. Original raw OCR is retained in reports;
classification evidence contains the actual focused observation and provenance.

The original pixel and OCR corpus is under
`DevelopmentFixtures/ClassifierReplaySources/low-result-title-20260911/`.
Tests cover the actual startup and EXP-to-loot sequence, unknown timeout without
refinement, original occlusion rejection, and invalid/ambiguous/conflicting
refinement inputs. Click targets, retries, deadlines, and input safety remain
unchanged. See `validation.json` for measured results. No live automation or
long-duration recovery run was performed for this fix.
