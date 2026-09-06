# Results

One file per run, named `<date>-<hostname>.md`. Each names the machine, the tool
versions and the hedge version it came from, because a number from a different
machine is a different number.

| run | hedge | notes |
| --- | --- | --- |
| [2026-09-05-D00](2026-09-05-D00.md) | 0.2.0 plus the fixes for #69, #70 and #71 | first published run |

Cells are marked one of three ways. An unmarked cell served every request it was
offered. A cell marked † served some and lost the rest, and keeps its numbers,
because a rate over what completed still says how far the server got. A cell
reading "served nothing" completed no request at all, and has no numbers because
a rate computed from zero completions is not a measurement. Every marked cell is
counted and explained at the bottom of the file.

To produce another:

```sh
./doc/bench/run.sh --smoke   # one short cell per protocol, writes nothing
./doc/bench/run.sh           # the full matrix, about 16 minutes
```
