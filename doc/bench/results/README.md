# Results

One file per run, named `<date>-<hostname>.md`. Each names the machine, the tool
versions and the hedge revision it came from, because a number from a different
machine is a different number.

Nothing is published here yet. hedge currently fails three of the four protocol
rows, for reasons filed as
[#69](https://github.com/briar-systems/hedge/issues/69),
[#70](https://github.com/briar-systems/hedge/issues/70) and
[#71](https://github.com/briar-systems/hedge/issues/71). The first run lands
once those close.

The harness is finished and reproducible in the meantime:

```sh
./doc/bench/run.sh --smoke   # one short cell per protocol
./doc/bench/run.sh           # the full matrix
```
