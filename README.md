# dub-packages-indexer

This little tool:

- scrapes metadata from code.dlang.org every 15min
- updates github.com/skoppe/dub-packages-index
- updates dub.bytecraft.nl (github.com/skoppe/dub-registry-mirror)

The scheduler is run by github actions.

## Use it

`dub --registry="https://dub.bytecraft.nl"`
