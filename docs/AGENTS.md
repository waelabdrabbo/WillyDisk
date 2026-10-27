# docs — agent notes

- `ARCHITECTURE.md` — the frozen architecture and shared-contracts document. §3 and §4
  are the frozen data model and scanning contract, §6 the compatibility rules, §7 the
  shared-interface rules, §8 the non-negotiables. A change to a shared interface is a
  design change: explain it and update this document in the same change. The layout
  sketch in §2 is illustrative, not exhaustive.
- `MEMORY.md` — the memory design and measured record: the one-tree rule (implemented:
  a scan that fills a `LiveTree` does not also keep the tree in its summary) and decision
  C, which keeps the arena linear with no stored-entry cap, plus the measured trigger for
  reopening it. Read it before changing what the engine retains or what the results
  screen reads.
