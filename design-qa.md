**Comparison Target**

- Source visual truth: `/var/folders/5f/x8ffcnvn2_14lh035c3p92180000gn/T/codex-clipboard-cdfe58f7-70b9-47da-ae3d-c897e58c9b46.png`
- Rendered implementation: `/Users/queen/Documents/aibar/docs/images/notch-capsule.png`
- Combined comparison evidence: `/tmp/aibar-notch-bridge-comparison.png` (source left, implementation right)
- Viewport: 292 x 64 pt at 2x display density
- Pixels: source 584 x 128; implementation 584 x 128; no density normalization required
- State: macOS physical-notch display, aibar demo quota wings and activity capsule visible

**Findings**

- No actionable P0, P1, or P2 differences remain for the requested change.
- Fonts and typography: quota numbers, project label, token count, and duration retain the existing size, weight, antialiasing, hierarchy, and truncation behavior.
- Spacing and layout rhythm: the left/right quota wings and activity capsule preserve their original geometry. The new black camera bridge is limited to the 22 pt system menu-bar thickness instead of the full 32 pt safe area.
- Colors and visual tokens: the bridge is pure black and visually joins the physical camera region. Existing blue, green, white, and gray status colors are unchanged.
- Image quality and asset fidelity: both captures are native 2x screenshots with matching crops and no resampling. No raster or icon asset was replaced.
- Copy and content: visible app copy is unchanged.

The item partially visible at the far-right crop edge and the window background below the menu bar belong to the surrounding macOS capture environment, not the aibar component.

**Focused Region Comparison**

The top 22 pt menu-bar band was inspected at native density. The implementation replaces only the former blue center gap with black; below that band, the capsule keeps its original independent rounded geometry. No additional focused crop was needed because all changed pixels are clearly readable in the full 584 x 128 evidence.

**Comparison History**

1. Earlier implementation used the full 32 pt safe-area height. It made the center fill visually too tall.
2. The bridge height was changed to `min(screen.safeAreaInsets.top, NSStatusBar.system.thickness)`, which resolves to 22 pt on the test Mac.
3. The bridge panel was placed one window level below status-bar content and configured to ignore mouse events. The post-fix implementation screenshot confirms the thinner black band stays behind the quota wings and activity capsule.

**Implementation Checklist**

- [x] Use system menu-bar thickness for the camera bridge.
- [x] Keep the bridge below all interactive notch content.
- [x] Preserve existing left/right quota and capsule dimensions.
- [x] Avoid a synthetic bridge on displays without a physical notch.
- [x] Verify the final 2x rendered screenshot and automated tests.

**Follow-up Polish**

- None required for this change.

final result: passed
