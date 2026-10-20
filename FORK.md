# Edge on a WHOOP 5: personal fork

This is upstream Edge as of 19 July 2026
([`25de96b`](https://github.com/OpenStrap/edge/commit/25de96b0c48a2378f0150876477a3b8c5db20e2e)),
plus my changes for daily use on a WHOOP 5, in one commit. I've tested it on my
iPhone with a WHOOP 5 and it works. No app builds are published here.

## What's new

- **Heart rate is kept.** Live HR is saved (up to once per second), so days still have HR when the band's history sync comes back incomplete. Historical readings take priority for the same second.
- **Recorded days.** Browse any saved day's HR average, minimum, maximum and chart.
- **Trends with partial history.** Week, Month and 3M open with the days that exist, e.g. *"Based on 2 of 7 days · partial period"*. Missing days stay as gaps.
- **Coverage shown.** Today, Heart and Body show how much of the day was recorded.
- **Anthropic coach.** The AI coach, briefings and journal use Anthropic's native Messages API when the provider is Anthropic. OpenAI-compatible providers still work.

## What I changed

- **No stand-in numbers.** Daytime HR is no longer used for resting HR or readiness, and stress no longer falls back to "100 − readiness".
- **Measured stats only.** HR stats come from recorded readings. HRV and sleep only use windows with enough data.
- **WHOOP 5 sync.** Guessed history timestamps are rejected, and history is only acknowledged once it has been saved.
- **Workouts.** Workout HR summaries are saved permanently and survive pruning and edits.
- **Re-analysis.** It includes days that were already finalised and reports errors.
- **Data format.** Database schema 25 → 27 (additive only) and analytics 44 → 45. After updating, run *Profile → Data → Re-analyze data* once.

## Relevance to upstream

I checked every change against upstream `main` on 20 October 2026
([`c8e6355`](https://github.com/OpenStrap/edge/commit/c8e63556225f1b77d015ca8a84adc8998a1e7d04)).
Upstream has moved a long way: 0.11.3, a rebuilt UI and schema 58. So code here
is a starting point for a rewrite, not something to copy across.

### ✅ Worth contributing

| Change here | What upstream is still missing |
|---|---|
| Native Anthropic coach | Claude is only reached through the OpenAI-compatible endpoint. |
| Re-analysis of finalised days | *Re-analyze everything* still skips finalised days, and a failure shows as "0 days". |
| Workout summary guards | A rescore after pruning can overwrite a workout's saved average and peak, and ending a finished workout again moves its end time. |
| Briefing date check | A manually generated briefing can describe an older night as last night. |
| Ordered, timestamped sync log | Lines written at start-up are dropped, and lines have no timestamps. |
| Partial-history ranges | 7- and 30-day views stay hidden until a full window exists. Upstream chose this deliberately, so it's a question for the maintainers. |

Smaller ideas:
- Show "<1%" rather than "0%" for tiny coverage.
- List days whose analysis failed or is only partial.
- Show a true sleeping-HR average. Upstream's "sleeping HR" is the lowest 30-minute average.

### ➖ Already in upstream

Upstream now handles all of these itself: WHOOP 5 support and decoding, acknowledging history only after it's saved, no stand-in numbers, gap-aware sleep and nightly HRV, saved workout HR, trend gaps with "N of M days" labels, browsing past days, the WHOOP export import fixes, and the sync log on iPhone.

### ⛔ Not suitable for upstream

- **Storing live HR (`live_hr`).** Upstream never stores live streams, by design. It now streams HR only during live views, and full WHOOP 5 history downloads work.
- **Raw per-second HR min/max.** A single spike becomes the day's peak; upstream filters spikes out.
- **Coverage from HR readings over clock time.** Upstream measures wear from recorded data, up to the last sync.
- **iOS changes (AccessorySetupKit and the WHOOP 5 clock turned off).** Upstream fixed pairing within AccessorySetupKit, and porting these would break it.

## Known issues

The same review found these in this fork. They should be fixed before an installable build is shared:

- **HRV.** The new continuity check rejects a whole night if two beats share a second, which happens often. Sleep HRV, breathing rate and stress can come out blank.
- **Older days.** `live_hr` is never pruned. Once a day's history has been pruned, its HR stats and workout charts come only from the leftover live readings.
- **Sleep edits.** Re-analysis includes finalised days by widening `force`, which sleep edits also use. So one sleep edit also rebuilds every other retained finalised day.
- **Decoder.** The pinned `protocol` (`c525e29`) drops whole seconds, HR included, during hard movement. This is fixed upstream.
- **Sync.** A storage failure during a timed save can leave a sync hanging. This is rare, e.g. with a full disk.

## Before switching

Back up first. This fork and current upstream use database schema 26–27 for
different changes, so moving a phone between them is not a tested upgrade.

## Build

```bash
cp .env.example .env
flutter pub get
flutter run --dart-define-from-file=.env
```

## Licence and names

The licence is MIT, as upstream's was at the base commit; upstream is now
AGPL-3.0. "OpenStrap" and its logo belong to the project
([TRADEMARKS.md](https://github.com/OpenStrap/edge/blob/main/TRADEMARKS.md)), so
if you distribute a build, give it your own name and icon. This fork is not
affiliated with WHOOP.
