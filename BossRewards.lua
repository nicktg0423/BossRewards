--- Boss Rewards
--- After every Boss Blind, Cash Out opens a pack of three rewards: choose one.
---
--- DROP 1 OF 3 (27 Sep 2026): the menu machinery and the six instant rewards,
--- #2 #3 #5 #6 #7 #11. v0.1.1, same day: the reward opens straight from Cash Out.
--- DROP 2 (v0.2.0, 29 Sep): the targeted rewards #8 #10 #15 (highlight a Joker or
--- a consumable, then Use) and the deck rewards #13 #14 (Use opens a picker of the
--- whole deck). Nick tested it: "it worked very well."
--- DROP 3 (v0.3.0, 29 Sep): #1 and #9 open a second pack (Vouchers, Rare Jokers);
--- #4 and #12 open picker screens like the deck picker (Nick's call, 29 Sep). All
--- 15 rewards are in. Plan: project doc claude/boss_rewards_build_plan.md.
---
--- BUILT AGAINST WHAT NICK RUNS, NOT VANILLA AND NOT A FRESH CLONE.
---   Steamodded 1.0.0~BETA-1620a, installed at Mods\smods\ ("smods/..." below)
---   the patched game code lovely dumped on 25 Sep, Mods\lovely\dump\ ("dump/..." below)
--- Line numbers below point into those two, checked 27 Sep.
---
--- HOW IT FITS TOGETHER
---   1. A boss dies. Steamodded sends every mod an end-of-round signal carrying
---      beat_boss (dump/functions/state_events.lua:107). This mod rolls three
---      offers and appends them to a queue saved on the run (G.GAME.ntgbr).
---   2. The cash-out screen shows a cobalt Cash Out button with "+ Boss Reward".
---   3. Cash Out pays out as normal, and the reward pack opens BEFORE the shop is
---      built (Nick, 27 Sep, after testing Drop 1: the shop popping up first
---      "interrupts it"). The pack opens the way a Tag opens a free pack
---      (dump/tag.lua:230). When it closes, the shop is built as usual.
---   4. Taking a reward, or closing the pack any other way, removes that menu
---      from the queue. #1 and #9 put their own pack at the front of the queue as
---      they are taken, and it opens the same way once the menu has closed.
---
--- SAVE AND RESUME. The game never saves while a pack is open
--- (dump/functions/misc_functions.lua:1591). The cash-out screen saves on arrival
--- with the queued menu in it, so a quit mid-menu resumes at Cash Out with the
--- same three offers. After the pack closes, the shop is only built once the
--- closing pack's own save has run, so no save ever holds a half-built shop.
---
--- A MENU CAN STILL OPEN OVER A BUILT SHOP, for Test mode (Ctrl+B in a shop) and
--- for a continued Drop 1 save. That path waits until the shop is idle: built,
--- filled, saved, and nothing held or locked.
---
--- NEXT ROUND IS LEFT ALONE, BY DESIGN. It is a one-press button
--- (dump/functions/UI_definitions.lua:708, dump/engine/ui.lua:1044), and greying
--- it risks trapping the player if a menu ever failed to open.
---
--- EVERY ROLL IS SEEDED. pseudorandom with this mod's own seed keys, never
--- math.random: same seed plus same picks gives the same run.

local THIS_MOD = SMODS.current_mod          -- must be captured at load time
local cfg      = THIS_MOD.config

----------------------------------------------------------------------
-- Config.
----------------------------------------------------------------------
if cfg.enabled   == nil then cfg.enabled   = true  end
if cfg.test_mode == nil then cfg.test_mode = false end
cfg.test_offers = cfg.test_offers or {}

--- Only a CHANGED shipped default needs a version bump: Steamodded writes config
--- to disk and an `== nil` line never fires again once the key exists.
local CONFIG_VERSION = 1
if cfg.cfg_version ~= CONFIG_VERSION then cfg.cfg_version = CONFIG_VERSION end

local COBALT = HEX('0047AB')
local LIGHT  = HEX('4A9EFF')

----------------------------------------------------------------------
-- Module state.
----------------------------------------------------------------------
local BR = {
    order = {},         -- reward center keys in list order ('c_ntgbr_cash', ...)
    label = {},         -- center key -> short label, for the config tab and logs
    num = {},           -- center key -> its number in the locked list

    -- Session state. Deliberately NOT saved: all of it describes this session's
    -- timeline, and Game:start_run resets it.
    saved = true,        -- the game has saved since the queue last changed
    shop_ready = false,  -- the current shop has been built and filled
    shop_loading = false,-- the current shop is being restored from a save
    open = nil,          -- { offers = {...}, resolved = bool } while the menu pack is open
    deferred_shop = false, -- a reward pack opened before the shop was built
    picker = nil,        -- the deck picker's state while it is on screen (#13, #14)
    picked = nil,        -- { card = reward card, cards = {...} } from Confirm until use()
    use_card_wrapped = false,
}

local function log(msg)
    sendInfoMessage(msg, 'BossRewards')
end

--- The run's saved state. Created lazily, so runs started before the mod was
--- installed, and older saves, pick it up without special handling.
local function run_state()
    G.GAME.ntgbr = G.GAME.ntgbr or {}
    G.GAME.ntgbr.queue = G.GAME.ntgbr.queue or {}
    return G.GAME.ntgbr
end

----------------------------------------------------------------------
-- Art. Nick's call C, 27 Sep: "a blank card with just a short description on
-- it for now." Faces are rendered by tools/make_faces.py in the game's own font.
-- 4x4 grid of 71x95 cells, the vanilla Tarot cell size.
----------------------------------------------------------------------
SMODS.Atlas {
    key = 'rewards',
    path = 'rewards.png',
    px = 71,
    py = 95,
}

----------------------------------------------------------------------
-- The card type. Its key is NOT prefixed by Steamodded
-- (prefix_config = { key = false }, smods/src/game_object.lua:1089).
--
-- The type badge on a consumable is drawn in SECONDARY_SET, so cobalt goes
-- there. shop_rate is left nil, which Steamodded turns into a rate of 0
-- (game_object.lua Game:init_game_object), so these never appear in a shop.
----------------------------------------------------------------------
SMODS.ConsumableType {
    key = 'BossReward',
    primary_colour = LIGHT,
    secondary_colour = COBALT,
    collection_rows = { 5, 5, 5 },
    loc_txt = {
        name = 'Boss Reward',
        collection = 'Boss Rewards',
        undiscovered = {
            name = 'Not Discovered',
            text = { 'Beat a Boss Blind', 'to see this reward' },
        },
    },
}

----------------------------------------------------------------------
-- Reward helper.
--
-- Every reward:
--   * never spawns anywhere on its own (in_pool false)
--   * MUST define can_use: a Steamodded consumable without one falls through to
--     vanilla's name checks and comes back false (dump/card.lua:1856 onward), which
--     would grey out Use forever
--   * calls BR.take() before anything else in use(), which removes its menu from
--     the queue while the pack is still open, so the save after the pack closes
--     already reflects the pick
----------------------------------------------------------------------
local function reward(def)
    local key = 'c_ntgbr_' .. def.key
    SMODS.Consumable {
        key = def.key,
        set = 'BossReward',
        atlas = 'rewards',
        pos = def.pos,
        --- ability.name is what RunLogger writes into its log (RunLogger.lua
        --- card_info), so it carries the reward's number from the locked list.
        name = 'Boss Reward #' .. def.num .. ': ' .. def.label,
        loc_txt = { name = def.label, text = def.text },
        config = {},
        cost = 0,
        unlocked = true,
        discovered = true,
        in_pool = function(self, args) return false end,
        can_use = def.can_use or function(self, card) return true end,
        loc_vars = def.loc_vars,
        use = function(self, card, area, copier)
            BR.take(self.key)
            def.use(self, card, area, copier)
        end,
    }
    BR.order[#BR.order + 1] = key
    BR.label[key] = '#' .. def.num .. ' ' .. def.label
    BR.num[key] = def.num
end

--- The standard "a card was used" beat, as vanilla's own consumables do it.
local function juice(card, sound)
    G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
        play_sound(sound or 'tarot1')
        card:juice_up(0.3, 0.5)
        return true
    end }))
end

----------------------------------------------------------------------
-- THE SIX INSTANT REWARDS. Numbers are from the locked list, backlog entry 38.
-- Tooltip wording is Nick's exact phrasing; grey lines are rules the build adds.
----------------------------------------------------------------------

--- #2. Antimatter's slot line (dump/card.lua:2294), queued the way Antimatter
--- queues it. Under Steamodded, card_limit is a metatable field
--- (smods/lovely/card_limit.toml), so "+1" moves the area's own modifier.
---
--- The Eternal target must be able to hold Eternal: set_eternal refuses anything
--- without eternal_compat, and anything Perishable (dump/card.lua:667). Eleven
--- vanilla Jokers are not compatible, Luchador and Invisible Joker among them.
--- If nothing qualifies, the slot comes with no downside (approved 27 Sep).
reward {
    key = 'eternal_slot', num = 2, pos = { x = 1, y = 0 },
    label = '+1 Joker Slot',
    text = {
        '{C:dark_edition}+1{} Joker slot,',
        'a random Joker turns {C:attention}Eternal{}',
        '{C:inactive}(Only Jokers that can be Eternal.{}',
        '{C:inactive}If none can, just the slot){}',
    },
    use = function(self, card)
        local eligible = {}
        for _, j in ipairs(G.jokers.cards) do
            if j.config.center.eternal_compat and not j.ability.eternal and not j.ability.perishable then
                eligible[#eligible + 1] = j
            end
        end
        --- pseudorandom_element sorts cards by sort_id before drawing
        --- (dump/functions/misc_functions.lua:290), so the pick is reproducible.
        local target = eligible[1] and pseudorandom_element(eligible, pseudoseed('ntgbr_eternal')) or nil

        G.E_MANAGER:add_event(Event({ func = function()
            if G.jokers then G.jokers.config.card_limit = G.jokers.config.card_limit + 1 end
            return true
        end }))
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
            play_sound('tarot1')
            card:juice_up(0.3, 0.5)
            if target and target.area == G.jokers then
                target:set_eternal(true)
                target:juice_up(0.5, 0.5)
                card_eval_status_text(target, 'extra', nil, nil, nil, { message = 'Eternal!', colour = HEX('c75985') })
            end
            return true
        end }))
        delay(0.6)
    end,
}

--- #3. Hieroglyph's ante lines (dump/card.lua:2301-2304) without its hand
--- penalty, plus Paint Brush's hand size line (dump/card.lua:2285).
---
--- The menu opens after the boss has already raised the Ante
--- (dump/functions/state_events.lua:190), so the normal flow never goes below
--- Ante 1. No floor is added: Test mode at Ante 1, or a Hieroglyph bought during
--- Ante 1, can reach Ante 0, which the game already handles.
reward {
    key = 'rewind', num = 3, pos = { x = 2, y = 0 },
    label = 'Go Back 1 Ante',
    text = {
        'Go back {C:attention}1{} Ante,',
        'and gain {C:attention}+1{} hand size',
    },
    use = function(self, card)
        juice(card)
        ease_ante(-1)
        G.GAME.round_resets.blind_ante = G.GAME.round_resets.blind_ante or G.GAME.round_resets.ante
        G.GAME.round_resets.blind_ante = G.GAME.round_resets.blind_ante - 1
        G.hand:change_size(1)
        delay(0.6)
    end,
}

--- #5. Grabber and Wasteful, exactly (dump/card.lua:2280-2290). The Hands counter
--- goes 4 to 5 and stays; it is not a +1 that grows every round (Nick, 27 Sep).
reward {
    key = 'hand_discard', num = 5, pos = { x = 0, y = 1 },
    label = '+1 Hand, +1 Discard',
    text = {
        '{C:blue}+1{} hand and {C:red}+1{} discard,',
        'permanently',
    },
    use = function(self, card)
        juice(card)
        G.GAME.round_resets.hands = G.GAME.round_resets.hands + 1
        ease_hands_played(1)
        G.GAME.round_resets.discards = G.GAME.round_resets.discards + 1
        ease_discard(1)
        delay(0.6)
    end,
}

--- #6. The Investment Tag's payout, doubled.
reward {
    key = 'cash', num = 6, pos = { x = 1, y = 1 },
    label = 'Gain $50',
    text = { 'Gain {C:money}$50{}' },
    use = function(self, card)
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
            play_sound('timpani')
            card:juice_up(0.3, 0.5)
            ease_dollars(50, true)
            return true
        end }))
        delay(0.6)
    end,
}

--- #7. The Hermit (dump/card.lua:1707-1713) with the cap raised from $20 to
--- $200. The Hermit's own max(0, ...) is what stops it doubling a Credit Card
--- debt: at $0 or below it pays $0 (approved 27 Sep).
local function double_money_gain()
    local dollars = (G.GAME and G.GAME.dollars) or 0
    return math.max(0, math.min(dollars, 200))
end

reward {
    key = 'double_money', num = 7, pos = { x = 2, y = 1 },
    label = 'Double Your Money',
    text = {
        'Double your money,',
        'up to {C:money}+$200{}',
        '{C:inactive}(Currently {C:money}+$#1#{C:inactive}){}',
    },
    loc_vars = function(self, info_queue, card)
        return { vars = { double_money_gain() } }
    end,
    use = function(self, card)
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
            play_sound('timpani')
            card:juice_up(0.3, 0.5)
            ease_dollars(double_money_gain(), true)
            return true
        end }))
        delay(0.6)
    end,
}

--- #11. The Soul's shape (dump/card.lua, The Soul branch of use_consumeable),
--- with two changes the verification pass required:
---   * the rarity is asked for BY NAME. A number in that slot is read as a random
---     roll, so "4" silently comes back as a Rare
---     (dump/functions/common_events.lua:2242).
---   * its own key_append. With the name, the pool key becomes
---     'Joker4ntgbr_leg<ante>' (common_events.lua:2246, :2345), a stream of its own,
---     instead of The Soul's 'Joker4'. The edition roll gets its own stream too.
--- Owned Legendaries are skipped unless Showman, like The Soul.
reward {
    key = 'legendary', num = 11, pos = { x = 2, y = 2 },
    label = 'Legendary Joker',
    text = {
        'A random {C:legendary,E:1}Legendary{} Joker',
        '{C:inactive}(Must have room){}',
    },
    can_use = function(self, card)
        return G.jokers and #G.jokers.cards < G.jokers.config.card_limit
    end,
    use = function(self, card)
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
            play_sound('timpani')
            local joker = SMODS.create_card({
                set = 'Joker', area = G.jokers, rarity = 'Legendary', key_append = 'ntgbr_leg',
            })
            joker:add_to_deck()
            G.jokers:emplace(joker)
            check_for_unlock({ type = 'spawn_legendary' })
            card:juice_up(0.3, 0.5)
            return true
        end }))
        delay(0.6)
    end,
}

----------------------------------------------------------------------
-- DROP 2: THE TARGETED REWARDS, #8 #10 #15. Highlight a Joker (or a held
-- consumable), then Use the reward. Jokers and consumables stay clickable while
-- a pack is open, and clicking a pack card never unhighlights them: the only
-- unhighlight_all on the Joker area in the game is a boss's (dump/blind.lua:217).
-- Use greys out while nothing valid is highlighted: the Use button asks can_use
-- every frame (dump/functions/button_callbacks.lua:2117).
----------------------------------------------------------------------

--- The Joker the player has highlighted, if it is still a live Joker in the
--- Joker area. The area highlights at most one (highlight_limit 1, dump/game.lua:2306).
local function highlighted_joker()
    local j = G.jokers and G.jokers.highlighted and G.jokers.highlighted[1]
    if j and j.area == G.jokers and not j.removed and not j.getting_sliced then return j end
end

local function highlighted_consumable()
    local c = G.consumeables and G.consumeables.highlighted and G.consumeables.highlighted[1]
    if c and c.area == G.consumeables and not c.removed and not c.getting_sliced then return c end
end

--- #8. Ectoplasm's edition line (dump/card.lua:1790-1820) on a chosen Joker, without
--- its hand size cost. Under Steamodded, set_edition takes the old edition's slot
--- back before adding Negative's (smods/src/overrides.lua:2066), so it replaces any
--- edition cleanly. An already-Negative Joker greys Use out (default E, 27 Sep).
reward {
    key = 'negative', num = 8, pos = { x = 3, y = 1 },
    label = 'Negative Joker',
    text = {
        'Choose a Joker,',
        'make it {C:dark_edition}Negative{}',
        '{C:inactive}(Highlight a Joker, then Use.{}',
        '{C:inactive}Replaces its edition){}',
    },
    loc_vars = function(self, info_queue, card)
        info_queue[#info_queue + 1] = G.P_CENTERS.e_negative
        return {}
    end,
    can_use = function(self, card)
        local j = highlighted_joker()
        return j and not (j.edition and j.edition.negative) and true or false
    end,
    use = function(self, card)
        local target = highlighted_joker()
        if not target then return end
        log('Negative: ' .. tostring(target.config.center.key))
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
            if target.area == G.jokers then
                target:set_edition({ negative = true }, true)
                check_for_unlock({ type = 'have_edition' })
            end
            card:juice_up(0.3, 0.5)
            return true
        end }))
        delay(0.6)
    end,
}

--- #10. Ankh's copy lines (dump/card.lua:1748-1776) on a chosen Joker, with nothing
--- destroyed. The copy is never Negative: copy_card's strip_edition also takes the
--- copied slot back (dump/functions/common_events.lua:2522), so it needs a free slot
--- like any new Joker. It keeps the original's stickers, as Ankh's copy does.
reward {
    key = 'duplicate', num = 10, pos = { x = 1, y = 2 },
    label = 'Duplicate a Joker',
    text = {
        'Choose a Joker,',
        'duplicate it',
        '{C:inactive}(Highlight a Joker, then Use.{}',
        '{C:inactive}Must have room. The copy{}',
        '{C:inactive}is never Negative){}',
    },
    can_use = function(self, card)
        return highlighted_joker() and #G.jokers.cards < G.jokers.config.card_limit and true or false
    end,
    use = function(self, card)
        local target = highlighted_joker()
        if not target then return end
        log('Duplicate: ' .. tostring(target.config.center.key))
        juice(card)
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.2, func = function()
            if target.area ~= G.jokers then return true end
            local copy = copy_card(target, nil, nil, nil, target.edition and target.edition.negative)
            copy:start_materialize()
            copy:add_to_deck()
            --- Never true after strip_edition (copy_card skips set_edition then,
            --- common_events.lua:2488). Kept because it is Ankh's own line (card.lua:1771).
            if copy.edition and copy.edition.negative then copy:set_edition(nil, true) end
            G.jokers:emplace(copy)
            return true
        end }))
        delay(0.6)
    end,
}

--- #15. Perkeo's copy lines (dump/card.lua:2811-2818) on a chosen consumable,
--- three times. Negative copies carry their own slot, so a full row is fine.
reward {
    key = 'cons_copies', num = 15, pos = { x = 2, y = 3 },
    label = 'Copy a Consumable',
    text = {
        'Choose a held consumable,',
        'make {C:attention}3{} {C:dark_edition}Negative{} copies',
        '{C:inactive}(Highlight it, then Use){}',
    },
    loc_vars = function(self, info_queue, card)
        info_queue[#info_queue + 1] = { key = 'e_negative_consumable', set = 'Edition', config = { extra = 1 } }
        return {}
    end,
    can_use = function(self, card)
        return highlighted_consumable() and true or false
    end,
    use = function(self, card)
        local target = highlighted_consumable()
        if not target then return end
        log('Consumable copies: ' .. tostring(target.config.center.key))
        juice(card)
        for i = 1, 3 do
            G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.25, func = function()
                if target.removed then return true end
                local copy = copy_card(target, nil)
                copy:set_edition({ negative = true }, true)
                copy:add_to_deck()
                G.consumeables:emplace(copy)
                return true
            end }))
        end
        delay(0.4)
    end,
}

----------------------------------------------------------------------
-- THE PICKER SCREENS. Drop 2 built the deck picker for #13 and #14 (decision A,
-- 27 Sep: they pick from the WHOLE deck). Drop 3 adds two more screens on the same
-- frame, Nick's call on 29 Sep after using the deck picker: #4 lists your poker
-- hands, #12 shows the seals and the ranks. #1 and #9 stay packs (further down),
-- because what they offer are real cards.
--
-- HOW IT WORKS. Use on #4, #12, #13 or #14 does not use the card. It opens a
-- screen, and the menu pack waits underneath, untouched. Choose, then Confirm: the
-- screen closes and the reward is used for real, on that choice. Back closes the
-- screen with nothing spent, so the player can still take another reward or Skip.
-- Everything that happens after Confirm is the normal path of a card used from a
-- pack, so the queue, the pack closing and the saves are exactly Drop 1's.
--
-- WHY A SCREEN AND NOT A PACK. A pack leaves only the strip between the Jokers and
-- the pack cards, too short for four rows of 13, and a hand-type row lays its cards
-- out against G.hand in any pack state (dump/cardarea.lua:470), not against itself.
-- The screen is an overlay like View Deck, so it has the whole window.
--
-- BUILT FROM VIEW DECK. The rows are Steamodded's View Deck rows
-- (smods/src/overrides.lua:905): one 'title' CardArea per suit, four suits a page,
-- copies of your cards at 0.7 scale, sorted the same way. The copies are only for
-- display; nothing in the deck moves until Confirm. Three per-row overrides make a
-- 'title' row selectable (it refuses highlights otherwise, dump/cardarea.lua:135):
-- the picker counts selections across all rows, where a CardArea only counts its own.
--
-- WHILE IT IS OPEN the game is paused, as under any overlay. Events queued before it
-- opened wait (dump/engine/event.lua:50), so the menu pack cannot close underneath.
-- Nothing is saved, so a quit here resumes from the cash-out screen's save with the
-- same menu (v0.1.1). Esc does nothing (no_esc, dump/engine/controller.lua:806), so the
-- only ways out are Confirm and Back.
--
-- MOUSE ONLY, like #8 #10 #15. With a controller the game lets only the hand area
-- highlight (dump/cardarea.lua:136) and clears every other area's highlights each
-- frame (dump/cardarea.lua:296), so a gamepad cannot pick a Joker, a consumable or a
-- card here. Nothing locks up: Back and the menu's Skip still work.
----------------------------------------------------------------------
--- reward center key -> picker spec { kind, title, line1, line2 }, where kind is
--- 'deck' (#13 #14, which also carry min and max), 'hand' (#4) or 'seal_rank' (#12).
local PICKERS = {}

--- A rank counts only on a card that has one: Stone Cards count as rankless
--- (smods/src/utils.lua:1140), and #12 skips them (approved 27 Sep).
local function rank_counts()
    local counts = {}
    for _, c in ipairs(G.playing_cards or {}) do
        if c.base and c.base.value and not SMODS.has_no_rank(c) then
            counts[c.base.value] = (counts[c.base.value] or 0) + 1
        end
    end
    return counts
end

local function hand_name(hand) return localize(hand, 'poker_hands') end

local function seal_name(seal)
    local ok, name = pcall(localize, { type = 'name_text', set = 'Other', key = string.lower(seal) .. '_seal' })
    return (ok and type(name) == 'string' and name ~= 'ERROR') and name or (seal .. ' Seal')
end

local function rank_name(rank)
    local ok, name = pcall(localize, rank, 'ranks')
    return (ok and type(name) == 'string' and name ~= 'ERROR') and name or rank
end

--- The line under the title that says what Confirm will do.
local function picker_status()
    local P = BR.picker
    if not P then return end
    local kind = P.spec.kind
    if kind == 'deck' then
        P.status = P.count .. ' / ' .. P.spec.max .. ' selected'
    elseif kind == 'hand' then
        local h = P.hand and G.GAME.hands[P.hand]
        P.status = h and (hand_name(P.hand) .. ': level ' .. h.level .. ' -> ' .. (h.level * 2)) or 'Pick a poker hand'
    elseif kind == 'seal_rank' then
        if P.seal and P.rank then
            P.status = seal_name(P.seal) .. ' on ' .. (P.counts[P.rank] or 0) .. ' ' .. rank_name(P.rank) .. ' cards'
        elseif P.seal then
            P.status = seal_name(P.seal) .. ': pick a rank'
        elseif P.rank then
            P.status = rank_name(P.rank) .. ': pick a seal'
        else
            P.status = 'Pick a seal and a rank'
        end
    end
end

local function picker_valid(P)
    if not P then return false end
    local kind = P.spec.kind
    if kind == 'deck' then return P.count >= P.spec.min and P.count <= P.spec.max end
    if kind == 'hand' then return P.hand ~= nil and G.GAME.hands[P.hand] ~= nil end
    if kind == 'seal_rank' then return P.seal ~= nil and P.rank ~= nil and (P.counts[P.rank] or 0) > 0 end
    return false
end

local function row_can_highlight(self, card)
    return BR.picker ~= nil
end

--- A click on an unselected copy. #14 takes exactly one card, so a new click moves
--- the selection. #13 takes up to five, and a sixth click is refused the way the
--- game's own hand refuses one (dump/cardarea.lua:171).
local function row_add(self, card, silent)
    local P = BR.picker
    local orig = card.ntgbr_orig
    if not (P and orig) or P.selected[orig] then return end
    if P.spec.max == 1 then
        for _, row in ipairs(P.rows or {}) do
            for i = #row.highlighted, 1, -1 do
                local h = row.highlighted[i]
                table.remove(row.highlighted, i)
                h:highlight(false)
            end
        end
        P.selected, P.count = {}, 0
    elseif P.count >= P.spec.max then
        card:highlight(false)
        return
    end
    self.highlighted[#self.highlighted + 1] = card
    card:highlight(true)
    P.selected[orig] = true
    P.count = P.count + 1
    picker_status()
    if not silent then play_sound('cardSlide1') end
end

--- A click on a selected copy. The selection only changes without force: a card
--- leaving a row comes with force (dump/cardarea.lua:102). Tearing the rows down (a
--- page turn, or the screen closing) never even gets here, since remove_all takes each
--- card off the row's list before removing it (dump/functions/misc_functions.lua:145).
--- Either way the selection survives a page turn.
local function row_remove(self, card, force)
    for i = #self.highlighted, 1, -1 do
        if self.highlighted[i] == card then
            table.remove(self.highlighted, i)
            break
        end
    end
    card:highlight(false)
    local P = BR.picker
    if not force and P and card.ntgbr_orig and P.selected[card.ntgbr_orig] then
        P.selected[card.ntgbr_orig] = nil
        P.count = P.count - 1
        picker_status()
    end
end

local function row_unhighlight_all(self) end

--- The rows for the current page, built the way View Deck builds them
--- (smods/src/overrides.lua:909-963). The list is copied before sorting, where View
--- Deck sorts G.playing_cards itself.
local function picker_rows()
    local P = BR.picker
    local by_suit, suit_order = {}, {}
    for i = #SMODS.Suit.obj_buffer, 1, -1 do
        local s = SMODS.Suit.obj_buffer[i]
        by_suit[s] = {}
        suit_order[#suit_order + 1] = s
    end
    local cards = {}
    for _, c in ipairs(G.playing_cards) do cards[#cards + 1] = c end
    table.sort(cards, function(a, b) return a:get_nominal('suit') > b:get_nominal('suit') end)
    for _, c in ipairs(cards) do
        if c.base.suit and by_suit[c.base.suit] then table.insert(by_suit[c.base.suit], c) end
    end
    local visible = {}
    for _, s in ipairs(suit_order) do
        if by_suit[s][1] then visible[#visible + 1] = s end
    end

    P.pages = math.max(1, math.ceil(#visible / 4))
    P.page = math.min(P.page or 1, P.pages)
    P.rows = {}
    local rows = {}
    for j = (P.page - 1) * 4 + 1, math.min(#visible, P.page * 4) do
        local list = by_suit[visible[j]]
        local area = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, 6.5 * G.CARD_W, 0.6 * G.CARD_H, {
            card_limit = #list, type = 'title', view_deck = true, highlight_limit = P.spec.max,
            card_w = G.CARD_W * 0.7, draw_layers = { 'card' }, negative_info = 'playing_card',
        })
        area.can_highlight = row_can_highlight
        area.add_to_highlighted = row_add
        area.remove_from_highlighted = row_remove
        area.unhighlight_all = row_unhighlight_all
        for _, orig in ipairs(list) do
            local copy = copy_card(orig, nil, 0.7)
            copy.ntgbr_orig = orig
            copy.T.x = area.T.x + area.T.w / 2
            copy.T.y = area.T.y
            copy:hard_set_T()
            area:emplace(copy)
            if P.selected[orig] then
                area.highlighted[#area.highlighted + 1] = copy
                copy:highlight(true)
            end
        end
        P.rows[#P.rows + 1] = area
        rows[#rows + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0 }, nodes = {
            { n = G.UIT.O, config = { object = area } },
        } }
    end
    return rows
end

--- The part of the screen a page turn rebuilds: the rows, and the page cycle when
--- there are more than four suits (Steamodded's own paging, overrides.lua:1195).
local function picker_body()
    local P = BR.picker
    local nodes = {
        { n = G.UIT.R, config = { align = 'cm' }, nodes = {
            { n = G.UIT.C, config = { align = 'cm', padding = 0.1, r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = picker_rows() },
        } },
    }
    if P.pages > 1 then
        local options = {}
        for i = 1, P.pages do options[i] = localize('k_page') .. ' ' .. i .. '/' .. P.pages end
        nodes[#nodes + 1] = { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
            create_option_cycle({
                options = options, w = 4.5, cycle_shoulders = true, opt_callback = 'ntgbr_picker_page',
                current_option = P.page, colour = COBALT, no_pips = true,
                focus_args = { snap_to = true, nav = 'wide' },
            }),
        } }
    end
    return { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = nodes }
end

--- The idle colour of a choosable row or button: Run Info's poker hand row colour
--- (dump/functions/UI_definitions.lua:3219). A chosen one turns cobalt.
local function idle_colour() return darken(G.C.JOKER_GREY, 0.1) end

--- #4's list. One row per poker hand you can see in Run Info, in Run Info's order:
--- G.handlist filtered by SMODS.is_poker_hand_visible, as Steamodded's own Run Info
--- does (smods/src/overrides.lua:1622-1627). A secret hand shows once played.
--- Each row is Run Info's row (UI_definitions.lua:3217) made clickable, with the
--- level shown now and after doubling. Hovering shows the hand's example, like
--- Run Info.
local function visible_hands()
    local out = {}
    for _, h in ipairs(G.handlist or {}) do
        if G.GAME.hands[h] and SMODS.is_poker_hand_visible(h) then out[#out + 1] = h end
    end
    return out
end

local function level_pill(level)
    return { n = G.UIT.C, config = { align = 'cm', padding = 0.01, r = 0.1, minw = 1.3, outline = 0.8, outline_colour = G.C.WHITE,
        colour = G.C.HAND_LEVELS[math.max(0, math.min(7, level))] }, nodes = {
        { n = G.UIT.T, config = { text = localize('k_level_prefix') .. level, scale = 0.45, colour = G.C.UI.TEXT_DARK } },
    } }
end

local function hand_row(hand)
    local h = G.GAME.hands[hand]
    local level = h.level or 1
    return { n = G.UIT.R, config = { align = 'cm', padding = 0.05, r = 0.1, emboss = 0.05, hover = true, shadow = true,
        colour = idle_colour(), button = 'ntgbr_pick_hand', func = 'ntgbr_hand_row', ntgbr_hand = hand,
        on_demand_tooltip = { text = localize(hand, 'poker_hand_descriptions'), filler = { func = create_UIBox_hand_tip, args = hand } } }, nodes = {
        level_pill(level),
        { n = G.UIT.C, config = { align = 'cm', minw = 0.6 }, nodes = {
            { n = G.UIT.T, config = { text = '->', scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
        } },
        level_pill(level * 2),
        { n = G.UIT.C, config = { align = 'cl', minw = 4.2, maxw = 4.2 }, nodes = {
            { n = G.UIT.T, config = { text = '  ' .. hand_name(hand), scale = 0.45, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
        } },
        { n = G.UIT.C, config = { align = 'cm', padding = 0.05, colour = G.C.BLACK, r = 0.1 }, nodes = {
            { n = G.UIT.C, config = { align = 'cr', padding = 0.01, r = 0.1, colour = G.C.CHIPS, minw = 1.1 }, nodes = {
                { n = G.UIT.T, config = { text = number_format(h.chips, 1000000), scale = 0.45, colour = G.C.UI.TEXT_LIGHT } },
                { n = G.UIT.B, config = { w = 0.08, h = 0.01 } },
            } },
            { n = G.UIT.T, config = { text = 'X', scale = 0.45, colour = G.C.MULT } },
            { n = G.UIT.C, config = { align = 'cl', padding = 0.01, r = 0.1, colour = G.C.MULT, minw = 1.1 }, nodes = {
                { n = G.UIT.B, config = { w = 0.08, h = 0.01 } },
                { n = G.UIT.T, config = { text = number_format(h.mult, 1000000), scale = 0.45, colour = G.C.UI.TEXT_LIGHT } },
            } },
        } },
    } }
end

--- Twelve rows fit (vanilla's maximum). A modded game with more gets two columns.
local function hand_body()
    local hands = visible_hands()
    local per_col = #hands > 12 and math.ceil(#hands / 2) or #hands
    local cols = {}
    for i, hand in ipairs(hands) do
        local c = math.ceil(i / per_col)
        cols[c] = cols[c] or { n = G.UIT.C, config = { align = 'tm', padding = 0.05 }, nodes = {} }
        table.insert(cols[c].nodes, hand_row(hand))
    end
    return { n = G.UIT.C, config = { align = 'cm', padding = 0.1, r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = {
        { n = G.UIT.R, config = { align = 'cm' }, nodes = cols },
    } }
end

G.FUNCS.ntgbr_hand_row = function(e)
    local P = BR.picker
    e.config.colour = (P and P.hand == e.config.ntgbr_hand) and COBALT or idle_colour()
end

G.FUNCS.ntgbr_pick_hand = function(e)
    local P = BR.picker
    if not (P and e.config.ntgbr_hand) then return end
    P.hand = e.config.ntgbr_hand
    picker_status()   -- the click sound is the button's own (dump/engine/ui.lua:1067)
end

--- #12's screen. The seals are shown the way the Collection shows them, a blank
--- card carrying the seal (smods/src/ui.lua:2476-2487: G.P_CARDS.empty, c_base,
--- set_seal), in a 'title' row made selectable like the deck rows, one at a time.
--- Every seal the game knows is offered, in the Collection's order
--- (G.P_CENTER_POOLS.Seal). Hovering one shows its tooltip.
local function seal_add(self, card, silent)
    local P = BR.picker
    if not (P and card.ntgbr_seal) then return end
    for i = #self.highlighted, 1, -1 do
        local h = self.highlighted[i]
        table.remove(self.highlighted, i)
        h:highlight(false)
    end
    self.highlighted[#self.highlighted + 1] = card
    card:highlight(true)
    P.seal = card.ntgbr_seal
    picker_status()
    if not silent then play_sound('cardSlide1') end
end

local function seal_remove(self, card, force)
    for i = #self.highlighted, 1, -1 do
        if self.highlighted[i] == card then
            table.remove(self.highlighted, i)
            break
        end
    end
    card:highlight(false)
    local P = BR.picker
    if not force and P and P.seal == card.ntgbr_seal then
        P.seal = nil
        picker_status()
    end
end

local function seal_row()
    local P = BR.picker
    local seals = {}
    for _, center in ipairs(G.P_CENTER_POOLS.Seal or {}) do
        if center.key and G.P_SEALS[center.key] then seals[#seals + 1] = center.key end
    end
    local area = CardArea(G.ROOM.T.x + 0.2 * G.ROOM.T.w / 2, G.ROOM.T.h, math.max(1, #seals) * G.CARD_W * 0.95, 0.95 * G.CARD_H, {
        card_limit = math.max(1, #seals), type = 'title', highlight_limit = 1,
        card_w = G.CARD_W * 0.8, draw_layers = { 'card' },
    })
    area.can_highlight = row_can_highlight
    area.add_to_highlighted = seal_add
    area.remove_from_highlighted = seal_remove
    area.unhighlight_all = row_unhighlight_all
    for _, key in ipairs(seals) do
        local c = Card(area.T.x + area.T.w / 2, area.T.y, G.CARD_W * 0.8, G.CARD_H * 0.8, G.P_CARDS.empty, G.P_CENTERS.c_base)
        c:set_seal(key, true)
        c.ntgbr_seal = key
        area:emplace(c)
        if P.seal == key then
            area.highlighted[#area.highlighted + 1] = c
            c:highlight(true)
        end
    end
    return { n = G.UIT.O, config = { object = area } }
end

--- The ranks, Ace first like View Deck's rank column (smods/src/overrides.lua:1046),
--- with how many of each you own. A rank shows if you own one or it is in the pool,
--- View Deck's own rule (:1047), so a vanilla game shows all 13. A rank you own none
--- of is shown greyed and cannot be picked: it would seal nothing.
local function rank_button(key, count)
    local live = count > 0
    local rank = SMODS.Ranks[key]
    return { n = G.UIT.C, config = { align = 'cm', padding = 0.04 }, nodes = {
        { n = G.UIT.C, config = { align = 'cm', minw = 0.8, minh = 1.0, padding = 0.05, r = 0.1, emboss = 0.05,
            hover = live, shadow = live, colour = live and idle_colour() or G.C.UI.BACKGROUND_INACTIVE,
            button = live and 'ntgbr_pick_rank' or nil, func = live and 'ntgbr_rank_button' or nil, ntgbr_rank = key }, nodes = {
            { n = G.UIT.R, config = { align = 'cm' }, nodes = {
                { n = G.UIT.T, config = { text = (rank and rank.shorthand) or key, scale = 0.5, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
            } },
            { n = G.UIT.R, config = { align = 'cm' }, nodes = {
                { n = G.UIT.T, config = { text = 'x' .. count, scale = 0.32, colour = live and LIGHT or G.C.UI.TEXT_INACTIVE } },
            } },
        } },
    } }
end

local function rank_list(counts)
    local out = {}
    local buffer = SMODS.Rank.obj_buffer
    for i = #buffer, 1, -1 do
        local key = buffer[i]
        if (counts[key] or 0) > 0 or (SMODS.Ranks[key] and SMODS.add_to_pool(SMODS.Ranks[key], { suit = '' })) then
            out[#out + 1] = key
        end
    end
    return out
end

local function seal_rank_body()
    local P = BR.picker
    local buttons = {}
    for _, key in ipairs(rank_list(P.counts)) do buttons[#buttons + 1] = rank_button(key, P.counts[key] or 0) end
    return { n = G.UIT.C, config = { align = 'cm', padding = 0.1, r = 0.1, colour = G.C.BLACK, emboss = 0.05 }, nodes = {
        { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
            { n = G.UIT.T, config = { text = 'Seal', scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
        } },
        { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { seal_row() } },
        { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
            { n = G.UIT.T, config = { text = 'Rank', scale = 0.4, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
        } },
        { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = buttons },
    } }
end

G.FUNCS.ntgbr_rank_button = function(e)
    local P = BR.picker
    e.config.colour = (P and P.rank == e.config.ntgbr_rank) and COBALT or idle_colour()
end

G.FUNCS.ntgbr_pick_rank = function(e)
    local P = BR.picker
    if not (P and e.config.ntgbr_rank) then return end
    P.rank = e.config.ntgbr_rank
    picker_status()   -- the click sound is the button's own (dump/engine/ui.lua:1067)
end

local function text_row_light(text)
    return { n = G.UIT.R, config = { align = 'cm', padding = 0.02 }, nodes = {
        { n = G.UIT.T, config = { text = text, scale = 0.35, colour = G.C.UI.TEXT_LIGHT } },
    } }
end

local function picker_button(label, scale, minh, colour, button, func)
    return { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
        { n = G.UIT.C, config = { align = 'cm', minw = 2.8, minh = minh, padding = 0.1, r = 0.1, hover = true, shadow = true,
            colour = colour, button = button, func = func }, nodes = {
            { n = G.UIT.T, config = { text = label, scale = scale, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
        } },
    } }
end

local function picker_definition()
    local P = BR.picker
    local info = { n = G.UIT.C, config = { align = 'cm', padding = 0.1, minw = 3.4 }, nodes = {
        { n = G.UIT.R, config = { align = 'cm', padding = 0.08 }, nodes = {
            { n = G.UIT.T, config = { text = P.spec.title, scale = 0.6, colour = G.C.WHITE, shadow = true } },
        } },
        text_row_light(P.spec.line1),
        text_row_light(P.spec.line2),
        { n = G.UIT.R, config = { align = 'cm', padding = 0.15 }, nodes = {
            { n = G.UIT.T, config = { ref_table = P, ref_value = 'status', scale = 0.45, colour = LIGHT, shadow = true } },
        } },
        --- Built WITH its button, which the func then clears while the selection is
        --- not valid, like the game's own Use button. An element only becomes
        --- clickable if it has a button when it is built (dump/engine/ui.lua:391).
        picker_button('Confirm', 0.5, 0.75, G.C.UI.BACKGROUND_INACTIVE, 'ntgbr_picker_confirm', 'ntgbr_picker_can_confirm'),
        picker_button(localize('b_back'), 0.45, 0.6, G.C.ORANGE, 'ntgbr_picker_back', nil),
    } }
    local body
    if P.spec.kind == 'hand' then
        body = hand_body()
    elseif P.spec.kind == 'seal_rank' then
        body = seal_rank_body()
    else
        --- The deck's rows sit in their own box so a page turn can swap them.
        body = { n = G.UIT.O, config = { id = 'ntgbr_picker_body', object = UIBox {
            definition = picker_body(), config = { offset = { x = 0, y = 0 }, align = 'cm' },
        } } }
    end
    return create_UIBox_generic_options({
        no_back = true,
        outline_colour = COBALT,
        contents = {
            { n = G.UIT.R, config = { align = 'cm' }, nodes = {
                info,
                { n = G.UIT.B, config = { w = 0.2, h = 0.1 } },
                { n = G.UIT.C, config = { align = 'cm' }, nodes = { body } },
            } },
        },
    })
end

--- Opens the picker for a reward card sitting in the open menu. The game pauses
--- first, as every vanilla overlay does (dump/functions/button_callbacks.lua:1440),
--- so the screen is built paused.
function BR.open_picker(card, spec)
    BR.picker = { card = card, spec = spec, selected = {}, count = 0, page = 1 }
    if spec.kind == 'seal_rank' then BR.picker.counts = rank_counts() end
    picker_status()
    G.SETTINGS.paused = true
    --- As View Deck does (smods/src/overrides.lua:908): hides the real deck pile under
    --- the screen (dump/cardarea.lua:307). Closing the screen clears it
    --- (dump/functions/button_callbacks.lua:1385).
    G.VIEWING_DECK = true
    G.FUNCS.overlay_menu { definition = picker_definition(), config = { no_esc = true } }
    log('Picker opened: ' .. spec.title)
end

G.FUNCS.ntgbr_picker_page = function(args)
    local P = BR.picker
    if not (P and args and args.to_key) then return end
    P.page = args.to_key
    local holder = G.OVERLAY_MENU and G.OVERLAY_MENU:get_UIE_by_ID('ntgbr_picker_body')
    if not holder then return end
    if holder.config.object then holder.config.object:remove() end
    holder.config.object = UIBox {
        definition = picker_body(), config = { offset = { x = 0, y = 0 }, align = 'cm', parent = holder },
    }
    holder.UIBox:recalculate()
end

G.FUNCS.ntgbr_picker_can_confirm = function(e)
    if picker_valid(BR.picker) then
        e.config.colour = COBALT
        e.config.button = 'ntgbr_picker_confirm'
    else
        e.config.colour = G.C.UI.BACKGROUND_INACTIVE
        e.config.button = nil
    end
end

G.FUNCS.ntgbr_picker_back = function(e)
    BR.picker = nil
    G.FUNCS.exit_overlay_menu()
    log('Picker: Back')
end

--- Confirm: read the choice (for the deck, off the ORIGINAL cards), close the screen
--- (which unpauses), then use the reward exactly as its Use button would have.
G.FUNCS.ntgbr_picker_confirm = function(e)
    local P = BR.picker
    if not picker_valid(P) then return end
    local picked = { card = P.card }
    if P.spec.kind == 'deck' then
        picked.cards = {}
        for _, c in ipairs(G.playing_cards) do
            if P.selected[c] then picked.cards[#picked.cards + 1] = c end
        end
    elseif P.spec.kind == 'hand' then
        picked.hand = P.hand
    elseif P.spec.kind == 'seal_rank' then
        picked.seal, picked.rank = P.seal, P.rank
    end
    local card = P.card
    BR.picker = nil
    G.FUNCS.exit_overlay_menu()
    if not (card and G.pack_cards and card.area == G.pack_cards) then
        log('Picker: the reward card is gone, nothing applied')
        return
    end
    BR.picked = picked
    G.FUNCS.use_card({ config = { ref_table = card } })
end

--- The choice Confirm handed to this card's use(). Cleared on read, so a stale
--- choice can never reach a later use.
local function take_pick(card)
    local p = BR.picked
    BR.picked = nil
    if p and p.card == card then return p end
end

--- The deck picks, keeping only cards still in the deck.
local function take_picks(card)
    local p = take_pick(card)
    local alive = {}
    if not (p and p.cards) then return alive end
    for _, c in ipairs(p.cards) do
        if not c.removed then
            for _, pc in ipairs(G.playing_cards) do
                if pc == c then alive[#alive + 1] = c; break end
            end
        end
    end
    return alive
end

local function describe_cards(cards)
    local names = {}
    for i, c in ipairs(cards) do
        names[i] = tostring(c.base and c.base.value) .. ' of ' .. tostring(c.base and c.base.suit)
    end
    return table.concat(names, ', ')
end

--- #4, #12, #13 and #14 register a picker spec with their card. Use is live
--- whenever there is something to choose; the picker's Confirm does the rest.
local PICKER_CAN_USE = {
    deck = function() return G.playing_cards and G.playing_cards[1] and true or false end,
    hand = function() return G.handlist and G.GAME and G.GAME.hands and true or false end,
    seal_rank = function()
        for _, n in pairs(rank_counts()) do if n > 0 then return true end end
        return false
    end,
}

local function picker_reward(def)
    def.picker.kind = def.picker.kind or 'deck'
    PICKERS['c_ntgbr_' .. def.key] = def.picker
    local can = PICKER_CAN_USE[def.picker.kind]
    def.can_use = function(self, card) return can() end
    reward(def)
end
local deck_reward = picker_reward

--- #13. The Hanged Man's rule on up to five cards picked from the whole deck,
--- destroyed through Steamodded's destroy_cards, which marks glass as shattered
--- before the jokers hear about it (smods/src/utils.lua:2772). Glass Joker counts
--- shattered cards (dump/card.lua:3111) and Canio counts face cards, so both work.
--- The cards are shown in the play area first, then destroyed there.
deck_reward {
    key = 'remove', num = 13, pos = { x = 0, y = 3 },
    label = 'Remove Cards',
    text = {
        'Choose up to {C:attention}5{} cards,',
        'remove them from your deck',
        '{C:inactive}(Use opens your deck){}',
    },
    picker = { min = 1, max = 5, title = 'Remove Cards', line1 = 'Choose up to 5 cards', line2 = 'to remove from your deck' },
    use = function(self, card)
        local picks = take_picks(card)
        if not picks[1] then
            log('Remove Cards: nothing picked')
            return
        end
        log('Remove Cards: ' .. describe_cards(picks))
        for i, c in ipairs(picks) do
            if c.area ~= G.play then draw_card(c.area, G.play, i * 100 / #picks, 'up', nil, c, 0.08) end
        end
        --- immediate = true starts each card's destroy animation inside this event,
        --- so its removal is queued ahead of the closing pack's save.
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.6, func = function()
            play_sound('tarot1')
            card:juice_up(0.3, 0.5)
            SMODS.destroy_cards(picks, nil, true)
            --- destroy_cards skips a card something protects (SMODS.is_eternal,
            --- smods/src/utils.lua:2783) and flags only the cards it destroys (:2784).
            --- A protected card goes back to the deck: left in the play area it would be
            --- saved there and grey out every consumable's Use (dump/card.lua:1847).
            --- Nothing in vanilla or Nick's mods protects playing cards; this is a guard.
            for _, c in ipairs(picks) do
                if not c.getting_sliced and c.area == G.play then draw_card(G.play, G.deck, 50, 'up', nil, c) end
            end
            return true
        end }))
        delay(0.6)
    end,
}

--- #14. Cryptid (dump/card.lua:1527-1545) with three copies instead of two, on a card
--- picked from the whole deck. Outside a round the copies go to the deck rather than
--- the hand: the card and its copies are shown in the play area, then shuffled in,
--- the way Marble Joker adds a card. Hologram hears all three at once.
deck_reward {
    key = 'copies', num = 14, pos = { x = 1, y = 3 },
    label = 'Copy a Card',
    text = {
        'Choose a card,',
        'make {C:attention}3{} copies',
        '{C:inactive}(Use opens your deck){}',
    },
    picker = { min = 1, max = 1, title = 'Copy a Card', line1 = 'Choose a card', line2 = 'to make 3 copies of' },
    use = function(self, card)
        local orig = take_picks(card)[1]
        if not orig then
            log('Copy a Card: nothing picked')
            return
        end
        log('Copy a Card: ' .. describe_cards({ orig }))
        if orig.area ~= G.play then draw_card(orig.area, G.play, 50, 'up', nil, orig, 0.1) end
        local shown = { orig }
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
            play_sound('tarot1')
            card:juice_up(0.3, 0.5)
            local new_cards = {}
            for i = 1, 3 do
                G.playing_card = (G.playing_card and G.playing_card + 1) or 1
                local c = copy_card(orig, nil, nil, G.playing_card)
                c:add_to_deck()
                G.deck.config.card_limit = G.deck.config.card_limit + 1
                table.insert(G.playing_cards, c)
                G.play:emplace(c)
                c:start_materialize(nil, i > 1)
                new_cards[#new_cards + 1] = c
                shown[#shown + 1] = c
            end
            playing_card_joker_effects(new_cards)
            return true
        end }))
        delay(0.8)
        --- Back to the deck. Queued from inside an event that runs before the pack's
        --- own closing events, so the play area is empty again before the pack ends.
        G.E_MANAGER:add_event(Event({ func = function()
            for i, c in ipairs(shown) do
                if c.area == G.play then draw_card(G.play, G.deck, i * 100 / #shown, 'up', nil, c, 0.08) end
            end
            return true
        end }))
    end,
}

--- #4. A Planet's level up (level_up_hand, dump/functions/common_events.lua:470) with
--- the hand's current level as the amount, so level 3 becomes 6. Steamodded runs it
--- through upgrade_poker_hands (smods/src/utils.lua:3636), which shows the hand and
--- its new chips and mult in the HUD exactly as a Planet does, and tells the Jokers
--- the hand changed.
picker_reward {
    key = 'double_level', num = 4, pos = { x = 3, y = 0 },
    label = 'Double a Hand Level',
    text = {
        'Choose a poker hand,',
        'double its level',
        '{C:inactive}(Use opens your poker hands){}',
    },
    picker = { kind = 'hand', title = 'Double a Level', line1 = 'Choose a poker hand', line2 = 'to double its level' },
    use = function(self, card)
        local pick = take_pick(card)
        local hand = pick and pick.hand
        if not (hand and G.GAME.hands[hand]) then
            log('Double a Hand Level: nothing picked')
            return
        end
        local amount = G.GAME.hands[hand].level
        log('Double a Hand Level: ' .. hand .. ' from ' .. amount .. ' to ' .. (amount * 2))
        level_up_hand(card, hand, nil, amount)
    end,
}

--- #12. Deja Vu's seal line (set_seal with immediate, as Deja Vu and Talisman do)
--- on every card of the chosen rank you own now (approved 27 Sep), replacing any
--- seal already there. Stone Cards have no rank and are skipped. The cards are shown
--- in the play area while they are sealed, then go back to the deck, like #14.
picker_reward {
    key = 'seal_rank', num = 12, pos = { x = 3, y = 2 },
    label = 'Seal a Rank',
    text = {
        'Choose a seal and a rank:',
        'every card of that rank gets it',
        '{C:inactive}(Replaces any seal.{}',
        '{C:inactive}Stone Cards have no rank){}',
    },
    picker = { kind = 'seal_rank', title = 'Seal a Rank', line1 = 'Choose a seal and a rank', line2 = 'Every card of that rank gets it' },
    use = function(self, card)
        local pick = take_pick(card)
        if not (pick and pick.seal and pick.rank and G.P_SEALS[pick.seal]) then
            log('Seal a Rank: nothing picked')
            return
        end
        local targets = {}
        for _, c in ipairs(G.playing_cards) do
            if c.base and c.base.value == pick.rank and not SMODS.has_no_rank(c) then targets[#targets + 1] = c end
        end
        log('Seal a Rank: ' .. pick.seal .. ' on ' .. #targets .. ' x ' .. pick.rank)
        if not targets[1] then return end
        for i, c in ipairs(targets) do
            if c.area ~= G.play then draw_card(c.area, G.play, i * 100 / #targets, 'up', nil, c, 0.05) end
        end
        G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.4, func = function()
            play_sound('tarot1')
            card:juice_up(0.3, 0.5)
            return true
        end }))
        for _, c in ipairs(targets) do
            G.E_MANAGER:add_event(Event({ trigger = 'after', delay = 0.12, func = function()
                c:set_seal(pick.seal, nil, true)
                return true
            end }))
        end
        delay(0.5)
        --- Back to the deck, queued the same way as #14's.
        G.E_MANAGER:add_event(Event({ func = function()
            for i, c in ipairs(targets) do
                if c.area == G.play then draw_card(G.play, G.deck, i * 100 / #targets, 'up', nil, c, 0.05) end
            end
            return true
        end }))
    end,
}

----------------------------------------------------------------------
-- DROP 3: THE SUB-PACK REWARDS, #1 and #9 (decision B, 27 Sep: every choice is a
-- pack; kept for these two because what they offer are real cards).
--
-- Taking #1 or #9 puts a sub-pack at the FRONT of the queue. The menu then closes
-- normally, its closing save holds that sub-pack, and the sub-pack opens by the
-- same rules as a menu: before the shop is built (Game:update_shop, step B), or
-- over a built shop once it is idle. A pack opened from inside the closing pack's
-- own code would crash (dump/functions/button_callbacks.lua:2198, :2658), and this
-- never does. Closing the sub-pack, by a pick or by Skip, removes it from the
-- queue. A quit while it is open resumes into the same sub-pack, rolled again from
-- the same saved seed state.
----------------------------------------------------------------------
local function queue_sub(kind)
    local st = run_state()
    table.insert(st.queue, 1, { kind = kind })
    BR.saved = false
    log('Sub-pack queued: ' .. kind)
end

--- The Vouchers #1 may offer: the game's own Voucher pool (tier 2 only with its
--- tier 1, nothing already redeemed, nothing in a built shop's voucher slot,
--- dump/functions/common_events.lua get_current_pool), minus the vouchers the
--- UPCOMING shop will show. Those were chosen when the boss died
--- (dump/functions/state_events.lua:205) and the shop is only built after the
--- reward (v0.1.1), so the pool cannot see them yet. Showman does not matter: the
--- three are drawn without repeats here, not by the game's no-repeat rule, which
--- Showman switches off (smods/src/utils.lua:2883).
local function available_vouchers()
    local pool = get_current_pool('Voucher')
    local skip = {}
    local upcoming = G.GAME.current_round and G.GAME.current_round.voucher
    if type(upcoming) == 'table' then
        for _, k in ipairs(upcoming) do skip[k] = true end
    elseif type(upcoming) == 'string' then
        skip[upcoming] = true
    end
    local out, seen = {}, {}
    for _, k in ipairs(pool) do
        if k ~= 'UNAVAILABLE' and G.P_CENTERS[k] and not G.GAME.used_vouchers[k] and not skip[k] and not seen[k] then
            out[#out + 1] = k
            seen[k] = true
        end
    end
    return out
end

local function roll_vouchers(n)
    local pool = available_vouchers()
    local out = {}
    while #out < n and #pool > 0 do
        local key, idx = pseudorandom_element(pool, pseudoseed('ntgbr_vouchers'))
        out[#out + 1] = key
        table.remove(pool, idx)
    end
    return out
end

--- #1. Greys out only when no Voucher is left to offer, rather than opening an
--- empty pack.
reward {
    key = 'vouchers', num = 1, pos = { x = 0, y = 0 },
    label = 'See 3 Vouchers',
    text = {
        'See {C:attention}3{} Vouchers,',
        'choose {C:attention}1{}',
        "{C:inactive}(Never the shop's own Voucher){}",
    },
    can_use = function(self, card)
        return available_vouchers()[1] ~= nil
    end,
    use = function(self, card)
        juice(card)
        queue_sub('vouchers')
    end,
}

--- #9. Wraith's Rare as a five-card pick, without the money cost. The pack draws
--- through the game's own Joker pool (Jokers you own are skipped unless Showman),
--- with this mod's own seed key; its Select greys out with no free slot, as a
--- Buffoon pack's does (dump/functions/button_callbacks.lua:2127).
reward {
    key = 'rares', num = 9, pos = { x = 0, y = 2 },
    label = 'See 5 Rare Jokers',
    text = {
        'See {C:attention}5{} {C:red}Rare{} Jokers,',
        'choose {C:attention}1{}',
        '{C:inactive}(Must have room to take one){}',
    },
    use = function(self, card)
        juice(card)
        queue_sub('rares')
    end,
}

--- Use on #4, #12, #13 or #14 opens the picker instead of using the card. Wrapped at the
--- first run start, after every mod has loaded, so this sits outside RunLogger's
--- own use_card hook (RunLogger.lua:391): RunLogger then logs the use once, at
--- Confirm, and never logs a picker the player backed out of.
local function wrap_use_card()
    if BR.use_card_wrapped then return end
    BR.use_card_wrapped = true
    local ref_use_card = G.FUNCS.use_card
    G.FUNCS.use_card = function(e, mute, nosave)
        local card = e and e.config and e.config.ref_table
        local spec = card and card.config and card.config.center and PICKERS[card.config.center.key]
        if spec and G.pack_cards and card.area == G.pack_cards and not (BR.picked and BR.picked.card == card) then
            --- The Use button is one-press (dump/functions/UI_definitions.lua, use_and_sell_buttons):
            --- the click has already disabled it. Hand it back for after Back.
            e.disable_button = nil
            BR.open_picker(card, spec)
            return
        end
        return ref_use_card(e, mute, nosave)
    end
end

--- Test mode's three picks, stored as center keys so they survive later drops
--- reordering the list. Validated against this file's own list, because
--- G.P_CENTERS is not filled yet while mods load.
---
--- The list itself runs in the locked order (#2, #3, #5, ...), whatever order the
--- rewards are declared in: the roll and the config tab both read it.
table.sort(BR.order, function(a, b) return BR.num[a] < BR.num[b] end)
local function is_reward(k)
    for _, v in ipairs(BR.order) do if v == k then return true end end
    return false
end
for i = 1, 3 do
    if not is_reward(cfg.test_offers[i]) then
        cfg.test_offers[i] = BR.order[math.min(i, #BR.order)]
    end
end

----------------------------------------------------------------------
-- THE MENU PACK.
--
-- Never in a shop: in_pool false, which the RUNNING get_pack honours
-- (smods/src/overrides.lua:2444; the dumped version at
-- dump/functions/common_events.lua does not, which is why both were read).
-- Weight 0 as well.
--
-- Its contents come from BR.open.offers, set just before the pack opens. The
-- group label under the cards ("Boss Reward", "Choose 1") is built from
-- loc_txt.group_name (smods/src/game_object.lua:1480).
--
-- Drop 3's two sub-packs share everything but their size, their text and their
-- contents, so all three are declared through boss_pack.
----------------------------------------------------------------------
local function boss_pack(def)
    SMODS.Booster {
        key = def.key,
        kind = 'BossReward',
        name = def.name,
        atlas = 'rewards',
        pos = { x = 3, y = 3 },
        config = def.config,
        cost = 0,
        weight = 0,
        unlocked = true,
        discovered = true,
        no_collection = true,
        draw_hand = false,
        loc_txt = {
            name = 'Boss Reward',
            text = { def.text },
            group_name = 'Boss Reward',
        },
        in_pool = function(self, args) return false end,
        create_card = def.create_card,
        ease_background_colour = function(self)
            ease_colour(G.C.DYN_UI.MAIN, COBALT)
            ease_background_colour({ new_colour = COBALT, special_colour = G.C.BLACK, contrast = 2 })
        end,
        --- The Arcana pack's sparkles (smods/src/game_object.lua:1623), in brand colours.
        particles = function(self)
            G.booster_pack_sparkles = Particles(1, 1, 0, 0, {
                timer = 0.015,
                scale = 0.2,
                initialize = true,
                lifespan = 1,
                speed = 1.1,
                padding = -1,
                attach = G.ROOM_ATTACH,
                colours = { G.C.WHITE, LIGHT, COBALT },
                fill = true,
            })
            G.booster_pack_sparkles.fade_alpha = 1
            G.booster_pack_sparkles:fade(1, 0)
        end,
    }
end

boss_pack {
    key = 'menu',
    name = 'Boss Reward Pack',
    config = { extra = 3, choose = 1 },
    text = 'Choose {C:attention}#1#{} of {C:attention}#2#{} rewards',
    create_card = function(self, card, i)
        local offers = BR.open and BR.open.offers or {}
        return {
            key = offers[i] or BR.order[1],
            area = G.pack_cards,
            skip_materialize = true,
            no_edition = true,
        }
    end,
}

--- #1's pack. Its three are drawn when it opens (BR.open_next) and handed in here,
--- by key, the way the menu's are. A key that forces a card skips the pool and the
--- edition roll (dump/functions/common_events.lua, create_card; editions are only
--- rolled for Jokers). Taking one redeems it for free through Steamodded's own
--- pack path (dump/functions/button_callbacks.lua, use_card's Voucher branch).
boss_pack {
    key = 'vouchers',
    name = 'Boss Reward Vouchers',
    config = { extra = 3, choose = 1 },
    text = 'Choose {C:attention}#1#{} of {C:attention}#2#{} Vouchers',
    create_card = function(self, card, i)
        local offers = BR.open and BR.open.offers or {}
        return {
            key = offers[i] or offers[#offers] or 'v_blank',
            area = G.pack_cards,
            skip_materialize = true,
            no_edition = true,
        }
    end,
}

--- #9's pack. The rarity is asked for BY NAME ('Rare' becomes 3 in the pool code,
--- dump/functions/common_events.lua get_current_pool), with this mod's own
--- key_append, so the draw is 'Joker3ntgbr_rare<ante>' and the edition roll
--- 'edintgbr_rare<ante>'. Stake stickers roll on the stream every pack Joker
--- shares ('packetper', 'packssjr'), as a Buffoon pack's do.
boss_pack {
    key = 'rares',
    name = 'Boss Reward Rare Jokers',
    config = { extra = 5, choose = 1 },
    text = 'Choose {C:attention}#1#{} of {C:attention}#2#{} Rare Jokers',
    create_card = function(self, card, i)
        return {
            set = 'Joker',
            rarity = 'Rare',
            area = G.pack_cards,
            skip_materialize = true,
            key_append = 'ntgbr_rare',
        }
    end,
}

----------------------------------------------------------------------
-- The roll: three different rewards from the list, seeded.
----------------------------------------------------------------------
function BR.roll_offers()
    local pool = {}
    for _, k in ipairs(BR.order) do pool[#pool + 1] = k end
    local offers = {}
    while #offers < 3 and #pool > 0 do
        local key, idx = pseudorandom_element(pool, pseudoseed('ntgbr_menu'))
        offers[#offers + 1] = key
        table.remove(pool, idx)
    end
    return offers
end

local function describe(offers)
    local names = {}
    for i, k in ipairs(offers) do names[i] = BR.label[k] or k end
    return table.concat(names, ', ')
end

function BR.enqueue(offers, test)
    local st = run_state()
    st.queue[#st.queue + 1] = { offers = offers, test = test or nil }
    BR.saved = false
    log('Menu queued' .. (test and ' (test)' or '') .. ': ' .. describe(offers))
end

----------------------------------------------------------------------
-- Opening.
----------------------------------------------------------------------

--- Exactly the Charm Tag's steps (dump/tag.lua:230-240), with two differences:
--- the pack is sized to the offers, and use_card gets nosave = true. A pack
--- opened in the SHOP state otherwise saves a replay action pointing at the pack
--- card (dump/functions/button_callbacks.lua:2190), and this card lives in no
--- saved area, so the replay would find nothing. The queue already covers resume.
local function open_booster(center_key, size)
    local card = Card(G.play.T.x + G.play.T.w / 2 - G.CARD_W * 1.27 / 2,
        G.play.T.y + G.play.T.h / 2 - G.CARD_H * 1.27 / 2, G.CARD_W * 1.27, G.CARD_H * 1.27,
        G.P_CARDS.empty, G.P_CENTERS[center_key], { bypass_discovery_center = true, bypass_discovery_ui = true })
    card.cost = 0
    card.from_tag = true
    if size then card.ability.extra = size end

    --- An automatic open can land mid-click, which a pack the player opens by hand
    --- never does. The controller fixes a click's target on the PRESS
    --- (dump/engine/controller.lua:1121) and fires it on the RELEASE (:373), so a
    --- press on a shop button just before this and a release just after would
    --- still fire that button with the menu open: another pack's Open overwrites
    --- this one's state, and Next Round leaves the shop with the menu still up.
    --- shop_is_idle refuses to open while the mouse is held; this lock refuses new
    --- presses and releases while the shop slides away (locked presses and
    --- releases return early, controller.lua:1110 and :1133). no_delete keeps the
    --- unlock alive through a queue clear, and a stage change clears every lock
    --- anyway (dump/game.lua:1276).
    G.CONTROLLER.locks.ntgbr_open = true
    G.E_MANAGER:add_event(Event({
        trigger = 'after', delay = 0.6, blocking = false, blockable = false, no_delete = true,
        func = function()
            G.CONTROLLER.locks.ntgbr_open = nil
            return true
        end,
    }))

    G.FUNCS.use_card({ config = { ref_table = card } }, nil, true)
    card:start_materialize()
end

--- The shop is idle: built and filled, in place, no pack open, nothing locked,
--- not paused, and the game has saved since the queue last changed.
---
--- The shop's offset.py is only set while something has pushed the shop off
--- screen (use_card, dump/functions/button_callbacks.lua:2221) and is cleared when
--- it comes back, so "no py" means the shop is where it belongs.
---
--- G.SETTINGS.paused matters twice: the options menu is open, and pseudoseed
--- stops being seeded while paused (dump/functions/misc_functions.lua:330).
local function shop_is_idle()
    return G.STATE == G.STATES.SHOP and G.STATE_COMPLETE
        and G.shop and not G.shop.alignment.offset.py
        and not G.booster_pack and not G.pack_cards
        and BR.shop_ready and BR.saved
        and not G.SETTINGS.paused
        and not G.CONTROLLER.locked
        and not G.CONTROLLER.is_cursor_down
        and not G.CONTROLLER.locks.toggle_shop
        and not (G.GAME.STOP_USE and G.GAME.STOP_USE > 0)
end

--- A reward is waiting to be opened.
function BR.pending()
    local st = G.GAME and G.GAME.ntgbr
    return cfg.enabled and not BR.open and st and st.queue and st.queue[1] and true or false
end

--- Cash Out has been pressed and the shop has not been built yet. This is where
--- a boss's reward normally opens (Nick, 27 Sep: "you beat the boss, you hit one
--- button, and that pack opens up"). cash_out has already paid out, removed the
--- cash-out screen and switched to the SHOP state with STATE_COMPLETE false
--- (dump/functions/button_callbacks.lua:2968-3014); the shop itself is only built
--- by the next Game:update_shop, which the wrapper below holds back.
local function ready_before_shop()
    --- No check on G.round_eval: cash_out clears it in the same event that enters
    --- SHOP (dump/functions/button_callbacks.lua:2983), and delete_run never does,
    --- so a stale reference from an earlier session could block this forever.
    return G.STATE == G.STATES.SHOP and not G.STATE_COMPLETE
        and not G.shop
        and not G.booster_pack and not G.pack_cards
        and not G.SETTINGS.paused
        and not G.CONTROLLER.locked
        and not G.CONTROLLER.is_cursor_down
        and not (G.GAME.STOP_USE and G.GAME.STOP_USE > 0)
end

--- Drop 3's sub-packs, by queue kind. booster_size_mod (a modifier that adds cards
--- to every pack, dump/card.lua Card:open) is taken back out of #1's size, since
--- #1 only has its three.
local SUBPACKS = {
    vouchers = {
        booster = 'p_ntgbr_vouchers',
        open = function()
            local offers = roll_vouchers(3)
            return offers, #offers - ((G.GAME.modifiers or {}).booster_size_mod or 0), offers[1] ~= nil
        end,
    },
    rares = {
        booster = 'p_ntgbr_rares',
        open = function() return nil, nil, true end,
    },
}

--- Opens the first queued menu or sub-pack. Returns true if a pack was opened.
function BR.open_next()
    local st = run_state()
    local entry = st.queue[1]
    if not entry then return false end

    if entry.kind then
        local sub = SUBPACKS[entry.kind]
        local offers, size, ok
        if sub then offers, size, ok = sub.open() end
        if not ok then
            -- An unknown kind (a save from a later build), or #1 with nothing left
            -- to offer. Drop it rather than open an empty pack.
            table.remove(st.queue, 1)
            BR.saved = false
            log('Dropped a sub-pack that cannot open: ' .. tostring(entry.kind))
            return false
        end
        BR.open = { kind = entry.kind, offers = offers }
        log('Opening sub-pack: ' .. entry.kind .. (offers and (' (' .. table.concat(offers, ', ') .. ')') or ''))
        open_booster(sub.booster, size)
        return true
    end

    local offers = {}
    for i, k in ipairs(entry.offers or {}) do
        if G.P_CENTERS[k] then offers[#offers + 1] = k end
    end
    if not offers[1] then
        -- A queued menu whose rewards no longer exist (e.g. a save from a later
        -- build loaded into an earlier one). Drop it rather than open an empty pack.
        table.remove(st.queue, 1)
        BR.saved = false
        log('Dropped a queued menu with no known rewards')
        return false
    end

    BR.open = { offers = offers, resolved = false }
    log('Opening menu: ' .. describe(offers))
    wrap_use_card()   -- already done at run start; this only guarantees it
    --- Sized so the pack shows exactly the offers even if something sets
    --- booster_size_mod, which Card:open adds back (dump/card.lua:2058).
    open_booster('p_ntgbr_menu', #offers - ((G.GAME.modifiers or {}).booster_size_mod or 0))
    return true
end

--- A menu waiting in a shop that is ALREADY built: Test mode's Ctrl+B, or a
--- continued save from Drop 1, which opened menus over the shop. Opens over the
--- shop once it is idle.
function BR.try_open()
    if BR.pending() and shop_is_idle() then BR.open_next() end
end

----------------------------------------------------------------------
-- Resolution. A reward's use() calls BR.take while the pack is still open.
-- Any other way the pack closes (Skip, HandyBalatro's quick skip, anything
-- else that ends a pack) goes through G.FUNCS.end_consumeable, where an
-- untaken menu counts as skipped.
----------------------------------------------------------------------
function BR.take(center_key)
    if not (BR.open and not BR.open.kind and not BR.open.resolved) then return end
    BR.open.resolved = true
    local st = run_state()
    table.remove(st.queue, 1)
    BR.saved = false
    log('Taken: ' .. (BR.label[center_key] or center_key))
end

local ref_end_consumeable = G.FUNCS.end_consumeable
G.FUNCS.end_consumeable = function(e, delayfac)
    BR.picked = nil
    if BR.open then
        if BR.open.kind then
            --- A sub-pack is done whether a card was taken or it was skipped: the
            --- pick itself is the vanilla redeem or select, which needs nothing here.
            local st = run_state()
            table.remove(st.queue, 1)
            BR.saved = false
            log('Sub-pack closed: ' .. BR.open.kind)
        elseif not BR.open.resolved then
            local st = run_state()
            table.remove(st.queue, 1)
            BR.saved = false
            log('Skipped: ' .. describe(BR.open.offers))
        end
        BR.open = nil
    end
    return ref_end_consumeable(e, delayfac)
end

----------------------------------------------------------------------
-- THE CASH OUT BUTTON, when a boss reward is waiting. Nick's pick, 27 Sep: the
-- button turns cobalt and gets a second line, "+ Boss Reward", so the button you
-- press is the one that says a reward comes next.
--
-- The button is the 'bottom' row of the cash-out screen, built in
-- add_round_eval_row (dump/functions/common_events.lua:1296-1325; called from
-- evaluate_round, dump/functions/state_events.lua:1111). This copies that branch
-- exactly, with the colour and the extra line changed. Every other row, and the
-- button when nothing is waiting, goes to the game's own function untouched.
-- The menu is queued at end_of_round, before this screen is built, so the check
-- sees it. A Continue into the cash-out screen rebuilds the screen and sees it too.
----------------------------------------------------------------------
local ref_add_round_eval_row = add_round_eval_row
function add_round_eval_row(config)
    if not (config and config.name == 'bottom' and BR.pending()) then
        return ref_add_round_eval_row(config)
    end
    local scale = 0.9
    delay(0.4)
    G.E_MANAGER:add_event(Event({
        trigger = 'before', delay = 0.5,
        func = function()
            UIBox {
                definition = { n = G.UIT.ROOT, config = { align = 'cm', colour = G.C.CLEAR }, nodes = {
                    { n = G.UIT.R, config = { id = 'cash_out_button', align = 'cm', padding = 0.1, minw = 7, r = 0.15,
                        colour = COBALT, shadow = true, hover = true, one_press = true, button = 'cash_out',
                        focus_args = { snap_to = true } }, nodes = {
                        { n = G.UIT.C, config = { align = 'cm' }, nodes = {
                            { n = G.UIT.R, config = { align = 'cm' }, nodes = {
                                { n = G.UIT.T, config = { text = localize('b_cash_out') .. ': ', scale = 1, colour = G.C.UI.TEXT_LIGHT, shadow = true } },
                                { n = G.UIT.T, config = { text = localize('$') .. format_ui_value(config.dollars), scale = 1.2 * scale, colour = G.C.WHITE, shadow = true, juice = true } },
                            } },
                            { n = G.UIT.R, config = { align = 'cm' }, nodes = {
                                { n = G.UIT.T, config = { text = '+ Boss Reward', scale = 0.45, colour = G.C.WHITE, shadow = true } },
                            } },
                        } },
                    } },
                } },
                --- The game's offset is y = 0.4 into a 1.4-unit spacer. The second
                --- line makes the button taller, so it sits a little higher to stay
                --- clear of the first earnings row. Estimated, not measured: check it.
                config = { align = 'tmi', offset = { x = 0, y = 0.25 }, major = G.round_eval },
            }
            G.GAME.current_round.dollars = config.dollars
            play_sound('coin6', config.pitch or 1)
            G.VIBRATION = G.VIBRATION + 1
            return true
        end,
    }))
end

----------------------------------------------------------------------
-- Hooks.
----------------------------------------------------------------------

--- Mod-level calculate. Steamodded adds every mod with a calculate function as
--- an "individual" target (smods/src/utils.lua:2245, :2294).
---
--- THE END-OF-ROUND SIGNAL REACHES A MOD MORE THAN ONCE: once for the round, then
--- again for each card left in hand (smods/src/utils.lua:2144). Only the round-level
--- call has main_eval set (smods/src/utils.lua:2024), so the roll is gated on it.
---
--- beat_boss is just G.GAME.blind.boss. A Mr. Bones save on a boss still raises
--- the Ante, so it still earns the reward. On a real loss the run ends before any
--- shop, and the queued menu goes with it.
THIS_MOD.calculate = function(self, context)
    if not cfg.enabled then return end
    if context.end_of_round and context.main_eval and not context.individual and not context.repetition then
        if context.beat_boss then
            BR.enqueue(BR.roll_offers())
        end
    elseif context.starting_shop then
        -- A fresh shop is built and filled (dump/game.lua:3352).
        BR.shop_ready = true
    end
end

--- Runs every frame while the shop is up (Game:update calls it in SHOP only).
--- A restored shop is filled from G.load_shop_* by the shop's own build event
--- (dump/game.lua:3279-3325); those are staged at load (dump/game.lua:2392) and
--- cleared as they are used, so "all nil again" means the restored shop is filled.
local ref_update_shop = Game.update_shop
function Game:update_shop(dt)
    --- A. A Boss Rewards pack was opened before this shop existed and has now
    --- closed. Closing a pack returns to SHOP with STATE_COMPLETE still true (the
    --- pack's own update set it, smods/src/game_object.lua:1531), so the game would
    --- never build the shop: it is put back to "not built" here. It waits for the
    --- save the closing pack makes (dump/functions/button_callbacks.lua:2672), so
    --- that save holds SHOP with no shop in it, which rebuilds cleanly on Continue.
    --- Building first would let that save capture the shop's empty card areas
    --- before they are filled, and Continue would restore an empty shop.
    if BR.deferred_shop and BR.saved and not BR.open and not G.booster_pack and not G.pack_cards then
        BR.deferred_shop = false
        G.STATE_COMPLETE = false
    end

    --- B. A shop about to be built with a reward waiting: the reward first. The
    --- shop is not built until nothing is waiting. The last save before this is
    --- the cash-out screen's (dump/game.lua, Game:update_round_eval), which already
    --- holds the queued menu, so a quit mid-menu resumes at Cash Out with the
    --- same three offers.
    --- Not when a saved shop is being restored (G.load_shop_*, staged at load,
    --- dump/game.lua:2392): the save the pack makes on closing only writes real
    --- card areas (dump/functions/misc_functions.lua:1594), so it would drop the
    --- restored shop, and a later Continue would roll a new one. A continued shop
    --- is restored first and the menu opens over it (try_open, below). Found by
    --- the v0.1.1 review.
    local restoring = G.load_shop_jokers or G.load_shop_vouchers or G.load_shop_booster
    if not G.STATE_COMPLETE and not G.shop and not restoring and BR.pending() then
        BR.shop_ready = false
        if ready_before_shop() and BR.open_next() then
            BR.deferred_shop = true
        end
        return
    end

    if not G.STATE_COMPLETE then
        BR.shop_ready = false
        BR.shop_loading = (G.load_shop_jokers or G.load_shop_vouchers or G.load_shop_booster) and true or false
        --- A freshly built shop always waits for ITS OWN save (dump/game.lua:3354).
        --- Without this, a menu carried over from an earlier shop would find the old
        --- shop's "saved" still set and open a frame before the new shop saves.
        if not BR.shop_loading then BR.saved = false end
    end
    local ret = ref_update_shop(self, dt)
    if BR.shop_loading and not (G.load_shop_jokers or G.load_shop_vouchers or G.load_shop_booster) then
        BR.shop_loading = false
        BR.shop_ready = true
    end
    BR.try_open()
    return ret
end

--- A save made in the shop is what the next menu waits for. save_run returns
--- early inside any pack (dump/functions/misc_functions.lua:1591), so a call made
--- in the SHOP state is a real save, or saving is switched off entirely
--- (G.F_NO_SAVING), in which case there is nothing to wait for.
local ref_save_run = save_run
function save_run(...)
    local ret = ref_save_run(...)
    if G.STATE == G.STATES.SHOP then BR.saved = true end
    return ret
end

--- New run or Continue. Game:start_run sets the loaded state synchronously
--- (prep_stage, dump/game.lua:2057 and :1281). A run continued INTO the shop is
--- itself a shop save, so nothing is owed. Continued anywhere else, the next
--- menu waits for the next shop's own save, like a fresh run.
local ref_start_run = Game.start_run
function Game:start_run(args)
    BR.open = nil
    BR.shop_ready = false
    BR.shop_loading = false
    BR.deferred_shop = false
    BR.picker = nil
    BR.picked = nil
    wrap_use_card()
    local ret = ref_start_run(self, args)
    run_state()
    --- A run saved BEFORE this mod was installed has no bossreward_rate: Steamodded
    --- only writes the rates when a run is created (smods/src/game_object.lua:1169),
    --- a continued run loads G.GAME as saved (dump/game.lua:2072), and the shop sums
    --- every card type's rate with no nil guard (dump/functions/UI_definitions.lua:781),
    --- so the first shop fill would crash. Found by the Drop 1 review.
    G.GAME.bossreward_rate = G.GAME.bossreward_rate or 0
    BR.saved = (G.STATE == G.STATES.SHOP)
    return ret
end

----------------------------------------------------------------------
-- TEST MODE. Off by default. Ctrl+B in a shop queues a menu of the three
-- rewards picked in the config tab. The mod then saves the shop itself, since
-- the next menu waits for a shop save and none would come on its own.
----------------------------------------------------------------------
SMODS.Keybind {
    key = 'test_menu',
    key_pressed = 'b',
    held_keys = { 'lctrl' },
    event = 'pressed',
    action = function(self)
        if not (cfg.enabled and cfg.test_mode) then return end
        if G.STAGE ~= G.STAGES.RUN or G.STATE ~= G.STATES.SHOP or G.SETTINGS.paused then return end
        --- Only in a filled shop with no pack open: the save below must never capture
        --- a shop that is still being restored (dump/game.lua:3279-3325).
        if BR.open or not BR.shop_ready or not G.shop or G.booster_pack or G.pack_cards then return end
        local offers = {}
        for i = 1, 3 do
            local k = cfg.test_offers[i]
            if is_reward(k) then offers[#offers + 1] = k end
        end
        if not offers[1] then return end
        BR.enqueue(offers, true)
        save_run()
    end,
}

----------------------------------------------------------------------
-- Config tab.
--
-- create_option_cycle: options is a list, current_option a 1-based index, and
-- opt_callback names a G.FUNCS handler that receives args.to_key
-- (dump/functions/UI_definitions.lua:2107; same pattern as ColorBan).
----------------------------------------------------------------------
local function option_names()
    local names = {}
    for i, k in ipairs(BR.order) do names[i] = BR.label[k] end
    return names
end

local function index_of(k)
    for i, v in ipairs(BR.order) do if v == k then return i end end
    return 1
end

for i = 1, 3 do
    G.FUNCS['ntgbr_test_slot_' .. i] = function(args)
        cfg.test_offers[i] = BR.order[args.to_key]
    end
end

local function text_row(text, scale)
    return {
        n = G.UIT.R,
        config = { align = 'cm', padding = 0.05 },
        nodes = { { n = G.UIT.T, config = { text = text, scale = scale or 0.32, colour = G.C.UI.TEXT_LIGHT } } },
    }
end

THIS_MOD.config_tab = function()
    local cycles = {}
    for i = 1, 3 do
        cycles[#cycles + 1] = create_option_cycle({
            label = 'Test reward ' .. i,
            options = option_names(),
            current_option = index_of(cfg.test_offers[i]),
            opt_callback = 'ntgbr_test_slot_' .. i,
            w = 4.5,
            scale = 0.8,
            colour = COBALT,
        })
    end
    return {
        n = G.UIT.ROOT,
        config = { align = 'cm', padding = 0.1, colour = G.C.CLEAR },
        nodes = {
            { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
                create_toggle({ label = 'Enable Boss Rewards', ref_table = cfg, ref_value = 'enabled' }),
            } },
            text_row('After every Boss Blind, Cash Out opens a pack of three rewards. Choose one.'),
            { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = {
                create_toggle({ label = 'Test mode', ref_table = cfg, ref_value = 'test_mode' }),
            } },
            text_row('Test mode: Ctrl+B in any shop opens a menu with these three rewards.'),
            { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { cycles[1] } },
            { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { cycles[2] } },
            { n = G.UIT.R, config = { align = 'cm', padding = 0.05 }, nodes = { cycles[3] } },
        },
    }
end
