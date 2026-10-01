# BossRewards

After every Boss Blind in Balatro, Cash Out opens a pack of three rewards. Take one, or skip.

## How it works

Beat a Boss Blind and the Cash Out button turns blue with a second line, "+ Boss Reward". Cash Out pays out as normal, then the reward pack opens before the shop appears.

Each pack shows three different rewards drawn at random from the fifteen below. The same reward can come up again in a later pack. Every roll follows the run's seed, so the same seed and the same picks give the same offers.

## The rewards

| Reward | What it does |
|---|---|
| See 3 Vouchers, choose 1 | Opens a second pack of three Vouchers. Never the one the next shop is about to show, and never one you already own |
| +1 Joker slot, a random Joker turns Eternal | The slot is permanent. If none of your Jokers can be Eternal, you just get the slot |
| Go back 1 Ante, +1 hand size | The Ante counter goes back by one, so you play an extra Ante, which means another Boss Blind and another reward |
| Choose a poker hand, double its level | Shows every poker hand with its level now and after doubling |
| +1 hand and +1 discard, permanently | For every round from here on |
| Gain $50 | |
| Double your money, up to +$200 | At $0 or below it gives nothing |
| Choose a Joker, make it Negative | |
| See 5 Rare Jokers, choose 1 | Opens a second pack of five Rare Jokers |
| Choose a Joker, duplicate it | The copy is never Negative, and it needs a free Joker slot |
| A random Legendary Joker | Needs a free Joker slot |
| Choose a seal and a rank: every card of that rank gets it | Applies to every card of that rank in your deck at that moment. Stone Cards have no rank, so they are skipped |
| Choose up to 5 cards, remove them from your deck | The cards are destroyed, so anything that counts destroyed cards sees them |
| Choose a card, make 3 copies | |
| Choose a held consumable: 3 Negative copies | |

**Picking a target.** For the Joker and consumable rewards, highlight the card first, then press Use. The two deck rewards open your whole deck laid out like View Deck: click the cards you want, then Confirm. The seal reward opens one screen with every seal and every rank, showing how many of each rank you own.

You can still sell Jokers while any reward pack is open.

All fifteen rewards are in the Collection, under Boss Rewards.

## Installation

Requires Steamodded. Tested against 1.0.0~BETA-1620a.

Place the folder in your Balatro mods directory:

```
Balatro/
  Mods/
    BossRewards/
      BossRewards.json
      BossRewards.lua
      assets/
        1x/rewards.png
        2x/rewards.png
```

## Settings

Under Mods, Boss Rewards, Config.

| Setting | Default | What it does |
|---|---|---|
| Enable Boss Rewards | On | The whole mod |
| Test mode | Off | Press Ctrl+B in any shop to open a reward pack holding the three rewards picked below it. For trying out a specific reward |

## Compatibility

BossRewards adds a step between Cash Out and the shop after each Boss Blind. Mods that also change what happens at Cash Out or when the shop opens may conflict. Mods that only add Jokers, consumables, vouchers or decks should be fine.

## Credits

Built by NickTG for the channel.

Card faces use the m6x11 font by Daniel Linssen.

## License

MIT. See LICENSE.
