#!/usr/bin/env python3
"""Reads a spike 9 recording (output/…/spike9-<mode>-<known|unknown>.json) and says whether scrolling stayed smooth.

Per sample the app recorded the scroll view's offset and state (flags: 1 tracking, 2 dragging, 4 decelerating), and
compared the picture with the previous sample's: `shift` is how many points it moved down by the best match
(`residual`: 0 identical, towards 1 unrelated), `expected` is what the offset says it should have moved, and
`residualExpected` how well the two pictures match at that shift. Where the offset jumped by a logged correction
(`jump`: a chapter was added above and the position corrected), `expected` is what is left after taking the jump out:
the picture must keep moving at the finger's speed while the offset leaps by the chapter's height.

`shift` is the best match over every shift and can lock onto a multiple of the line height at speed, so the verdict
rests on `residualExpected`. A sample is
- late: the picture shows the previous sample's offset (the snapshot and the offset are not read at the same instant);
  the movement is owed to the next sample, whose `expected` includes it. Not a defect.
- slipped: the picture does not match where the offset says but matches well somewhere else, more than two points
  away. The text jumped.
- unmatched: the picture matches nothing (a blank band of unpainted tiles, or a jump further than the search range).

Usage: scripts/analyse-fling.py <recording.json> [--context N]
"""
import json
import sys


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    context = 4
    if "--context" in sys.argv:
        context = int(sys.argv[sys.argv.index("--context") + 1])
    data = json.load(open(args[0]))
    samples = data["samples"]
    events = data["events"]
    print(f"mode={data['mode']} known heights={data['preset']} margin={data['margin']} viewport={data['viewport']}")
    print(f"samples={len(samples)} span={samples[-1]['ms'] / 1000:.1f}s")

    for e in events:
        if e["ev"] in ("add", "loaded", "correct", "shift", "remove"):
            extra = {k: v for k, v in e.items() if k not in ("ev", "ms", "scrollY")}
            print(f"  event {e['ms']:9.1f} ms  {e['ev']:8s} {extra}")

    corrections = [e for e in events if e["ev"] == "correct"]
    MATCH = 0.45
    moving = jumps = late = 0
    slipped, unmatched = [], []
    for i in range(1, len(samples)):
        s = samples[i]
        if s["flags"] or samples[i - 1]["flags"]:
            moving += 1
        if "jump" in s:
            jumps += 1
        if s.get("late"):
            late += 1
            continue
        if s.get("residualExpected", 9) < MATCH:
            continue  # the picture is where the offset says
        if s.get("residual", 1) < MATCH:
            # One or two points apart is rounding: the offset moves by thirds of a point, the picture by whole rows.
            if abs(s.get("shift", 0) - s.get("expected", 0)) > 2:
                slipped.append(i)
        else:
            unmatched.append(i)
    blank = max(s["blankRun"] for s in samples)
    applied = sum(s.get("jump", 0) for s in samples)
    shifts = [e for e in events if e["ev"] == "shift"]
    print(f"samples moving (finger or momentum): {moving}")
    print(f"corrections taken out of the runway (no scroll position written): {len(shifts)} (sum {sum(c['by'] for c in shifts):.0f} px)")
    print(f"corrections logged by the page: {len(corrections)} (sum {sum(c['by'] for c in corrections):.0f} px); "
          f"offset jumps seen by the scroll view: {jumps} (sum {applied:.0f} px)")
    print(f"late samples (picture one sample behind the offset): {late}")
    print(f"SLIPPED samples (text jumped): {len(slipped)}")
    print(f"UNMATCHED samples (blank band or a far jump): {len(unmatched)}")
    print(f"longest run of rows without ink in any sample: {blank} pt (viewport {data['viewport'][1]:.0f})")
    # A blank screen: more than half of the viewport without ink, for as long as it lasts.
    episodes, run = [], []
    for i, s in enumerate(samples):
        if s["blankRun"] > data["viewport"][1] / 2:
            run.append(i)
        elif run:
            episodes.append(run)
            run = []
    if run:
        episodes.append(run)
    print(f"blank-screen episodes (more than half of the viewport without ink): {len(episodes)}")
    for e in episodes:
        first, last = samples[e[0]], samples[e[-1]]
        print(f"    from {first['ms']:.0f} ms for {last['ms'] - first['ms']:.0f} ms ({len(e)} samples)")
    # A correction the page owed and did not make: a chapter above changed height and nothing was scrolled or
    # shifted for it (the anchor element had been picked from a stale scroll position).
    answered = [e["ms"] for e in events if e["ev"] in ("correct", "shift") and e["reason"] == "resize"]
    for e in events:
        if e["ev"] == "height" and e["reason"] == "resize" and e["ms"] > 0 and e.get("old", 0) > 0:
            if not any(abs(ms - e["ms"]) <= 2 for ms in answered):
                print(f"  NOT CORRECTED: chapter {e['index']} went from {e['old']} to {e['h']} px at {e['ms']:.0f} ms")

    def row(i):
        s, p = samples[i], samples[i - 1]
        f = s["flags"]
        state = ("T" if f & 1 else "-") + ("D" if f & 2 else "-") + ("M" if f & 4 else "-")
        jump = f" jump {s['jump']:+.0f}" if "jump" in s else ""
        return (f"    {s['ms']:9.1f} ms {state} offset {s['offset']:10.1f} (d {s['offset'] - p['offset']:+9.1f}{jump})  "
                f"picture {s.get('shift', 0):+5d} (r {s.get('residual', 0):.3f})  expected {s.get('expected', 0):+5d} "
                f"(r {s.get('residualExpected', 0):.3f})  blank {s['blankRun']}")

    def show(title, i):
        print(f"  {title} at sample {i}")
        for j in range(max(1, i - context), min(len(samples), i + context + 1)):
            print(row(j) + ("   <==" if j == i else ""))

    for i in range(1, len(samples)):
        if "jump" in samples[i]:
            show("correction", i)
            still = bool(samples[min(len(samples) - 1, i + 3)]["flags"] & 4)
            print(f"    still decelerating three samples later: {still}")
    for i in slipped[:10]:
        show("SLIPPED", i)
    for i in unmatched[:10]:
        show("UNMATCHED", i)


if __name__ == "__main__":
    main()
