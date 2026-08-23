# Testing AutoDuck in a real room

Detection is the whole product, and it was tuned in one room on one Mac. Reports from other rooms,
speakers and Macs are the most useful contribution you can make. Here's how to produce one.

## Quality bar (what 1.0 must pass)
| Test | Target |
|---|---|
| Built-in speakers at 70 % volume, vocal pop music, nobody talking, 30 min | ≤ 1 false duck |
| Same music, a person says a normal sentence from 2 m | ducks within 1.5 s in ≥ 9 of 10 tries |
| Podcast/talk radio through the speakers at 70 %, 10 min | ≤ 2 false ducks (classifier mode) |
| Volume keys pressed while ducked | control returns to the user immediately, no re-duck until the conversation ends |
| Quit / kill / logout while ducked | volume restored |
| CPU on Apple Silicon while listening | < 5 % of one core; idle RAM < 60 MB |
| Audio retained anywhere on disk or network | none — verified by code review and a network monitor during a 1-hour run |

## Protocol

Room: your usual room, built-in speakers (or say what you used), default Sensitivity unless noted.
For each row in the table above:
1. Set the stated volume and source; start a timer; note every duck (time, what was happening).
2. For the talking tests: a second person says "Hey, can we talk for a second?" from 2 m, ten times,
   at least 15 s apart; note onset time from first word to fade start.
3. If you can, repeat on a second Mac model. Note the Sensitivity you ended up with and which rows
   passed or failed.

## Reporting

Open an issue titled `Room report: <Mac model> / <speakers>` with:
- the table rows you ran and the numbers (false ducks, onset times, misses),
- Sensitivity and detector mode used,
- a screenshot of the popover meters during a false trigger or a miss,
- the unified log around it:
  `/usr/bin/log show --predicate 'subsystem == "com.autoduck.app"' --last 5m --info`

If you're comfortable with it, `open build/AutoDuck.app --args --probe4 /path/to/a/song.mp3` writes
`~/Library/Logs/AutoDuck/probe.log` with raw vs. echo-cancelled levels — attach that too.
