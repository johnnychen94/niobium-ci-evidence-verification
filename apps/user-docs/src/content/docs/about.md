---
title: About the project
description: Why Niobium exists, who maintains it, and what support to expect.
---

Niobium is a hobby project maintained by one person, with no company support behind it. Expect best-effort maintenance, a deliberately narrow scope and a short platform list.

## Background

The author builds Niobium as a hobby project while working at TongYuan. Niobium is not part of TongYuan's commercial products.

The project exists to support creating installers for TongYuan products, whether internal, experimental or commercial. It is published as a general-purpose framework, and nothing in it is specific to those products.

TongYuan gives the project no direct support or steering, and there are no resources to support many platforms well.

## Maintenance strategy

- **Best effort, no service level.** There is one maintainer and no guaranteed response time for issues, pull requests or questions.
- **A deliberately narrow scope.** The [principles](/#principles) are not negotiable: requests for install scripts, hooks, plugins or other runtime extensions are declined, however useful they would be to one product. Product-specific behavior belongs in your application, through [App Bootstrap](/concepts/app-bootstrap/).
- **Few platforms, done properly.** Effort goes to the Tier 1 platforms first; the tiers and the roadmap are on [Platform support](/platforms/).
- **Pre-1.0.** Formats and interfaces may still change. Each change to a contract is recorded as a decision in the repository, and the verified state of each feature is on [Status and platforms](/status/).
- **Security reports** follow the process on [Security](/security/).
- **Contributions** are welcome when they follow the repository conventions in [AGENTS.md](https://github.com/niobium-project/niobium/blob/main/AGENTS.md). Merging a contribution is not guaranteed, and a contributed port needs someone who will keep it tested.
